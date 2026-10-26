#!/usr/bin/env bash
# node-validate.sh <cp|worker> <expected-hostname> <expected-ip>
# Read-only checks for one node. Prints one line per check:  PASS|check|detail  or  FAIL|check|detail
# plus INFO|asm-id|<by-id name> lines on workers. Run by 90-validate.ps1; safe to run by hand.

ROLE="${1:-worker}"
WANT_HOST="${2:-$(hostname)}"
WANT_IP="${3:-}"
HUGEPAGES_WANT="${HUGEPAGES_WANT:-2048}"

pass() { echo "PASS|$1|$2"; }
fail() { echo "FAIL|$1|$2"; }
check() {  # check <name> <detail> <command...>
  local name=$1 detail=$2; shift 2
  if "$@" >/dev/null 2>&1; then pass "$name" "$detail"; else fail "$name" "$detail"; fi
}

# ---------------- all nodes ----------------
h=$(hostname)
[[ "$h" == "$WANT_HOST" ]] && pass hostname "$h" || fail hostname "$h (want $WANT_HOST)"

ip4=$(ip -4 -o addr show enp0s3 2>/dev/null | awk '{print $4}' | head -1)
if [[ -z "$WANT_IP" || "$ip4" == "$WANT_IP/24" ]]; then pass ip-enp0s3 "$ip4"; else fail ip-enp0s3 "$ip4 (want $WANT_IP/24)"; fi

k=$(uname -r)
[[ "$k" == 5.15.0-*el9uek* ]] && pass kernel-uek-r7 "$k" || fail kernel-uek-r7 "$k (want 5.15.0-...el9uek)"

thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
[[ "$thp" == *"[madvise]"* ]] && pass thp-madvise "$thp" || fail thp-madvise "$thp"

cs=$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)
[[ "$cs" == tsc ]] && pass clocksource "$cs" || echo "WARN|clocksource|$cs (tsc recommended)"

se=$(getenforce)
[[ "$se" == Enforcing ]] && pass selinux "$se" || fail selinux "$se"

sw=$(swapon --noheadings | wc -l)
[[ "$sw" -eq 0 ]] && pass swap-off "0 swap devices" || fail swap-off "$sw swap devices"

for svc in crio kubelet chronyd; do
  s=$(systemctl is-active "$svc"); [[ "$s" == active ]] && pass "svc-$svc" "$s" || fail "svc-$svc" "$s"
done
s=$(systemctl is-active firewalld); [[ "$s" != active ]] && pass firewalld-off "$s" || fail firewalld-off "$s"

check crictl "crictl installed and talking to CRI-O" crictl info
check unzip "unzip installed" command -v unzip
check selinux-module "rac-ocne loaded" bash -c 'semodule -l | grep -qw rac-ocne'
b=$(getsebool container_manage_cgroup 2>/dev/null | awk '{print $3}')
[[ "$b" == on ]] && pass selinux-cgroup-bool "container_manage_cgroup on" || fail selinux-cgroup-bool "container_manage_cgroup ${b:-unknown} (systemd RAC pods will crash)"
check crio-selinux "CRI-O selinux = true" grep -qr '^selinux = true' /etc/crio/crio.conf.d/

v=$(sysctl -n fs.aio-max-nr); [[ "$v" == 1048576 ]] && pass sysctl-oracle "fs.aio-max-nr=$v" || fail sysctl-oracle "fs.aio-max-nr=$v"
v=$(sysctl -n net.ipv4.ip_forward); [[ "$v" == 1 ]] && pass sysctl-k8s "ip_forward=$v" || fail sysctl-k8s "ip_forward=$v"

if [[ -f /var/lib/kubelet/config.yaml ]]; then
  check kubelet-unsafe-sysctls "allowedUnsafeSysctls set" grep -q 'kernel.shm' /var/lib/kubelet/config.yaml
fi

[[ "$ROLE" == worker ]] || exit 0

# ---------------- workers only ----------------
size_gb() { echo $(( $(lsblk -bdno SIZE "$1") / 1024 / 1024 / 1024 )); }

for spec in "/scratch:80" "/var/lib/containers:100"; do
  mp=${spec%%:*}; want=${spec##*:}
  src=$(findmnt -n -o SOURCE --target "$mp" 2>/dev/null)
  if mountpoint -q "$mp"; then
    g=$(size_gb "$src"); (( g >= want - 2 && g <= want + 2 )) && pass "mount$mp" "$src ${g}G" || fail "mount$mp" "$src ${g}G (want ~${want}G)"
  else
    fail "mount$mp" "not mounted"
  fi
done

hp=$(awk '/HugePages_Total/{print $2}' /proc/meminfo)
[[ "$hp" == "$HUGEPAGES_WANT" ]] && pass hugepages "$hp" || fail hugepages "$hp (want $HUGEPAGES_WANT)"

for ifn in enp0s8 enp0s9; do
  flags=$(ip -o link show "$ifn" 2>/dev/null)
  addr=$(ip -4 -o addr show "$ifn" 2>/dev/null)
  if [[ "$flags" == *PROMISC* && "$flags" == *",UP"* && -z "$addr" ]]; then
    pass "nic-$ifn" "UP, PROMISC, no IPv4"
  else
    fail "nic-$ifn" "needs UP + PROMISC + no IPv4: $(echo "$flags" | grep -o '<[^>]*>') ${addr:+has IPv4}"
  fi
done

if [[ "$WANT_HOST" == worker1 ]]; then dirs="/scratch/rac/cluster01/node1 /scratch/software/stage /scratch/image"
else dirs="/scratch/rac/cluster01/node2"; fi
for d in $dirs; do
  ctx=$(ls -dZ "$d" 2>/dev/null | awk '{print $1}')
  [[ "$ctx" == *container_file_t* ]] && pass "dir$d" "$ctx" || fail "dir$d" "${ctx:-missing}"
done

# Shared ASM disks: whole ~50 GB disks, no partitions, no filesystem (ASM writes raw)
n=0
while read -r name; do
  [[ $(size_gb "/dev/$name") -ge 48 && $(size_gb "/dev/$name") -le 52 ]] || continue
  [[ $(lsblk -no NAME "/dev/$name" | wc -l) -eq 1 ]] || continue
  n=$((n + 1))
  fs=$(blkid -o value -s TYPE "/dev/$name" 2>/dev/null)
  id=""
  for l in /dev/disk/by-id/ata-VBOX_HARDDISK_*; do
    [[ "$(readlink -f "$l")" == "/dev/$name" ]] && id=$(basename "$l")
  done
  echo "INFO|asm-id|$id"
  # Blank before the Grid install; after it, ASM's own 'oracleasm' signature is expected. Any other
  # signature means the disk holds something else and must not be used for ASM.
  if [[ -z "$fs" ]]; then pass "asm-disk-$name" "$id blank (ready for the Grid install)"
  elif [[ "$fs" == oracleasm ]]; then pass "asm-disk-$name" "$id in use by ASM (expected after the Grid install)"
  else echo "WARN|asm-disk-$name|$id has signature '$fs' (expected blank or oracleasm)"; fi
done < <(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')
(( n == 2 )) && pass asm-disks "2 shared ~50G disks" || fail asm-disks "$n found (want 2)"
exit 0
