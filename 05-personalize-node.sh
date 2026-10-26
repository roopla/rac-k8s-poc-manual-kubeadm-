#!/usr/bin/env bash
# 05-personalize-node.sh <controlplane|worker1|worker2>
# Run as root on each fresh clone, from the VirtualBox console (all clones start on 10.0.1.5).
# Sets hostname, static IP, kubelet node IP. On workers it also:
#   - brings up enp0s8/enp0s9 with no IP (Multus macvlan masters)
#   - formats the 80 GB disk -> /scratch and the 100 GB disk -> /var/lib/containers
#     (found by SIZE: sdX names do not follow VirtualBox port order, so sdc can be an ASM disk)
#   - reserves hugepages and creates the doc's /scratch directories with SELinux contexts
# Reboots at the end.
#
# Rerun-safe: steps already done (mounted filesystems, existing dirs) are skipped.
# Optional overrides: SCRATCH_DEV=/dev/sdX CONT_DEV=/dev/sdY HUGEPAGES=2048 DNS=8.8.8.8

set -euo pipefail
NODE="${1:-}"
declare -A IPS=([controlplane]=10.0.1.10 [worker1]=10.0.1.11 [worker2]=10.0.1.12)
[[ -n "${IPS[$NODE]:-}" ]] || { echo "usage: $0 <controlplane|worker1|worker2>" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

IP="${IPS[$NODE]}"
GW=10.0.1.1
DNS="${DNS:-8.8.8.8}"
PUB_IF=enp0s3
PRIV1_IF=enp0s8
PRIV2_IF=enp0s9
SCRATCH_DEV="${SCRATCH_DEV:-}"
CONT_DEV="${CONT_DEV:-}"
HUGEPAGES="${HUGEPAGES:-2048}"

log() { echo -e "\n==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Delete every NetworkManager profile bound to an interface
del_con_for_if() {
  local ifn=$1 u
  while read -r u; do
    [[ -z "$u" ]] && continue
    if [[ "$(nmcli -g connection.interface-name con show "$u" 2>/dev/null)" == "$ifn" ]]; then
      nmcli con delete "$u" >/dev/null
    fi
  done < <(nmcli -g UUID con show)
  return 0   # without this, a non-matching last profile returns 1 and set -e ends the script
}

# Refuse to format anything that already has partitions, a filesystem, or the wrong size
check_blank_disk() {
  local dev=$1 want_gb=$2 size_gb
  [[ -b "$dev" ]] || die "$dev does not exist"
  [[ "$(lsblk -dno TYPE "$dev")" == "disk" ]] || die "$dev is not a whole disk"
  [[ $(lsblk -no NAME "$dev" | wc -l) -eq 1 ]] || die "$dev has partitions; refusing to format"
  [[ -z "$(blkid -o value -s TYPE "$dev" 2>/dev/null)" ]] || die "$dev already has a filesystem; refusing to format"
  size_gb=$(( $(lsblk -bdno SIZE "$dev") / 1024 / 1024 / 1024 ))
  (( size_gb >= want_gb - 2 && size_gb <= want_gb + 2 )) || die "$dev is ${size_gb} GB, expected ~${want_gb} GB"
}

# Print the one whole disk of about <gb> GB with no partitions and no filesystem
find_blank_disk_by_size() {
  local want_gb=$1 name size_gb found=()
  while read -r name; do
    size_gb=$(( $(lsblk -bdno SIZE "/dev/$name") / 1024 / 1024 / 1024 ))
    (( size_gb >= want_gb - 2 && size_gb <= want_gb + 2 )) || continue
    [[ $(lsblk -no NAME "/dev/$name" | wc -l) -eq 1 ]] || continue
    [[ -z "$(blkid -o value -s TYPE "/dev/$name" 2>/dev/null)" ]] || continue
    found+=("/dev/$name")
  done < <(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')
  (( ${#found[@]} == 1 )) || die "expected exactly one blank ~${want_gb} GB disk, found ${#found[@]}: ${found[*]:-none}"
  echo "${found[0]}"
}

log "Identity: hostname $NODE, machine-id, SSH host keys"
hostnamectl set-hostname "$NODE"
[[ -s /etc/machine-id ]] || systemd-machine-id-setup
ssh-keygen -A >/dev/null
echo "machine-id: $(cat /etc/machine-id)   product_uuid: $(cat /sys/class/dmi/id/product_uuid)"

log "Public NIC $PUB_IF -> $IP/24"
del_con_for_if "$PUB_IF"
nmcli con add type ethernet con-name pub ifname "$PUB_IF" \
  ipv4.method manual ipv4.addresses "$IP/24" ipv4.gateway "$GW" ipv4.dns "$DNS" \
  ipv6.method disabled connection.autoconnect yes >/dev/null

echo "KUBELET_EXTRA_ARGS=\"--node-ip=${IP}\"" >/etc/sysconfig/kubelet

if [[ "$NODE" == worker* ]]; then
  log "Private NICs $PRIV1_IF, $PRIV2_IF: up, no IP (Multus macvlan masters)"
  for ifn in "$PRIV1_IF" "$PRIV2_IF"; do
    ip link show "$ifn" >/dev/null 2>&1 || die "$ifn not found; check VirtualBox adapters 2 and 3"
    del_con_for_if "$ifn"
    nmcli con add type ethernet con-name "rac-$ifn" ifname "$ifn" \
      ipv4.method disabled ipv6.method disabled 802-3-ethernet.mtu 1500 \
      802-3-ethernet.accept-all-mac-addresses yes connection.autoconnect yes >/dev/null
    # accept-all-mac-addresses = promiscuous mode. VirtualBox's "Allow All" only takes effect
    # when the guest NIC is promiscuous; without it the emulated NIC drops frames for the
    # macvlan (pod) MAC addresses and the RAC interconnect is silent.
  done

  if mountpoint -q /var/lib/containers; then
    log "/var/lib/containers already on its own disk, skipping"
  else
    [[ -n "$CONT_DEV" ]] || CONT_DEV=$(find_blank_disk_by_size 100)
    log "/var/lib/containers on $CONT_DEV (100 GB)"
    check_blank_disk "$CONT_DEV" 100
    systemctl stop kubelet crio
    mkfs.xfs -q -f -L containers "$CONT_DEV"
    mkdir -p /mnt/newcont
    mount "$CONT_DEV" /mnt/newcont
    rsync -aAXH /var/lib/containers/ /mnt/newcont/      # keep pre-pulled images and SELinux labels
    umount /mnt/newcont && rmdir /mnt/newcont
    echo "UUID=$(blkid -o value -s UUID "$CONT_DEV")  /var/lib/containers  xfs  defaults  0 0" >>/etc/fstab
    systemctl daemon-reload
    mount /var/lib/containers
    restorecon -R /var/lib/containers
  fi

  if mountpoint -q /scratch; then
    log "/scratch already on its own disk, skipping"
  else
    [[ -n "$SCRATCH_DEV" ]] || SCRATCH_DEV=$(find_blank_disk_by_size 80)
    log "/scratch on $SCRATCH_DEV (80 GB)"
    check_blank_disk "$SCRATCH_DEV" 80
    mkfs.xfs -q -f -L scratch "$SCRATCH_DEV"
    mkdir -p /scratch
    echo "UUID=$(blkid -o value -s UUID "$SCRATCH_DEV")  /scratch  xfs  defaults  0 0" >>/etc/fstab
    systemctl daemon-reload
    mount /scratch
  fi

  log "Doc directories under /scratch with container_file_t context"
  if [[ "$NODE" == worker1 ]]; then
    DIRS=(/scratch/rac/cluster01/node1 /scratch/software/stage /scratch/image)
  else
    DIRS=(/scratch/rac/cluster01/node2)
  fi
  for d in "${DIRS[@]}"; do
    mkdir -p "$d"
    semanage fcontext -a -t container_file_t "${d}(/.*)?" 2>/dev/null || \
      semanage fcontext -m -t container_file_t "${d}(/.*)?"
    restorecon -RF "$d"
  done

  log "HugePages: vm.nr_hugepages=$HUGEPAGES ($(( HUGEPAGES * 2 / 1024 )) GB)"
  echo "vm.nr_hugepages = $HUGEPAGES" >/etc/sysctl.d/92-hugepages.conf
  sysctl -q -p /etc/sysctl.d/92-hugepages.conf
  grep -E 'HugePages_Total|Hugepagesize' /proc/meminfo
fi

log "Done. Rebooting in 5 s. From Windows afterwards: ssh -p $((2200 + ${IP##*.})) root@127.0.0.1"
sleep 5
reboot
