#!/usr/bin/env bash
# 02-prep-golden.sh
# Run ONCE as root on the golden VM (Oracle Linux 9.8, minimal install) before cloning.
# Prepares everything that is identical on all three nodes:
#   OS updates, UEK R7 pinned, kernel args, swap off, k8s + Oracle sysctls,
#   SELinux packages + the doc's rac-ocne policy module, CRI-O + kubeadm/kubelet/kubectl, podman.
#
# BEFORE RUNNING: copy the SELinux policy text from the Oracle doc section
#   "Set up SELinux Module on Worker Nodes" (the rac-ocne.te file) into /root/rac-ocne.te
#
# Optional overrides: K8S_MINOR=v1.36 CRIO_MINOR=v1.36 ./02-prep-golden.sh

set -euo pipefail
K8S_MINOR="${K8S_MINOR:-v1.36}"
CRIO_MINOR="${CRIO_MINOR:-v1.36}"
TE_FILE="${TE_FILE:-/root/rac-ocne.te}"

log() { echo -e "\n==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
[[ -f "$TE_FILE" ]] || die "$TE_FILE not found. Copy rac-ocne.te from the Oracle doc first."

log "1/10 Update the OS"
dnf -y install dnf-plugins-core
dnf -y update

log "2/10 Pin UEK R7 (the Oracle doc is tested on UEK R7 5.15.0-208 or later)"
dnf repolist --all | grep -q '^ol9_UEKR7' || die "repo ol9_UEKR7 not found; check: dnf repolist --all | grep -i uek"
dnf config-manager --set-enabled ol9_UEKR7
dnf config-manager --set-disabled ol9_UEKR8 2>/dev/null || true
UEK7=$(dnf -q --disablerepo='*' --enablerepo=ol9_UEKR7 repoquery --latest-limit 1 \
        --qf '%{version}-%{release}' kernel-uek | tail -1)
[[ -n "$UEK7" ]] || die "could not find a UEK R7 kernel in ol9_UEKR7"
echo "Latest UEK R7: $UEK7"
dnf -y install "kernel-uek-${UEK7}"
grubby --set-default "/boot/vmlinuz-${UEK7}.x86_64"

log "3/10 Kernel arguments: THP=madvise (doc, UEK7+) and clocksource=tsc (doc, VMs)"
grubby --update-kernel=ALL --args="transparent_hugepage=madvise clocksource=tsc"

log "4/10 Disable swap"
swapoff -a || true
sed -ri '/\sswap\s/ s/^([^#])/#\1/' /etc/fstab

log "5/10 Kernel modules and sysctls"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/90-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Values from the Oracle doc, "Prepare the Worker Node for Oracle RAC Deployment"
cat >/etc/sysctl.d/91-oracle-rac.conf <<'EOF'
fs.file-max = 6815744
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
fs.aio-max-nr = 1048576
EOF
sysctl --system >/dev/null

log "6/10 Time sync (chronyd) and firewall (disabled for the lab)"
dnf -y install chrony
systemctl enable --now chronyd
systemctl disable --now firewalld 2>/dev/null || true

log "7/10 Tools, SELinux packages and the rac-ocne policy module"
dnf -y install container-selinux selinux-policy-devel policycoreutils-python-utils \
               podman tar rsync unzip jq iproute-tc bash-completion lsof
mkdir -p /var/opt
cp "$TE_FILE" /var/opt/rac-ocne.te
( cd /var/opt && make -f /usr/share/selinux/devel/Makefile rac-ocne.pp && semodule -i rac-ocne.pp )
semodule -l | grep -q rac-ocne || die "rac-ocne SELinux module not loaded"
# systemd as PID 1 in a pod (the doc's RAC pods) must manage its own cgroups. Without this
# boolean the RAC container exits about 1 s after starting, with no log output.
# OCNE sets it through its olcne-selinux package; kubeadm does not.
setsebool -P container_manage_cgroup on
[[ "$(getenforce)" == "Enforcing" ]] || echo "WARNING: SELinux is not Enforcing; the doc expects Enforcing"

log "8/10 Kubernetes ${K8S_MINOR} and CRI-O ${CRIO_MINOR} repositories"
cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
cat >/etc/yum.repos.d/cri-o.repo <<EOF
[cri-o]
name=CRI-O
baseurl=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_MINOR}/rpm/repodata/repomd.xml.key
EOF
dnf -y install cri-o kubelet kubeadm kubectl cri-tools --disableexcludes=kubernetes
echo "runtime-endpoint: unix:///var/run/crio/crio.sock" >/etc/crictl.yaml

log "9/10 Configure CRI-O (SELinux on, no default bridge CNI)"
mkdir -p /etc/crio/crio.conf.d
cat >/etc/crio/crio.conf.d/90-rac-poc.conf <<'EOF'
[crio.runtime]
selinux = true
EOF
# Use the same sandbox (pause) image kubeadm expects, so only one is pulled
PAUSE_IMG=$(kubeadm config images list 2>/dev/null | grep '/pause:' | head -1)
[[ -n "$PAUSE_IMG" ]] && printf '[crio.image]\npause_image = "%s"\n' "$PAUSE_IMG" >/etc/crio/crio.conf.d/91-pause.conf
# Flannel and Multus provide the networks; remove CRI-O's sample bridge config if present
rm -f /etc/cni/net.d/*crio*bridge* 2>/dev/null || true
for p in macvlan host-local bridge portmap loopback; do
  [[ -x /opt/cni/bin/$p || -x /usr/libexec/cni/$p ]] || echo "WARNING: CNI plugin '$p' not found in /opt/cni/bin or /usr/libexec/cni"
done
systemctl enable --now crio
systemctl enable kubelet
kubeadm config images pull --cri-socket unix:///var/run/crio/crio.sock

log "10/10 /etc/hosts and shell conveniences"
grep -q 'controlplane' /etc/hosts || cat >>/etc/hosts <<'EOF'
10.0.1.10  controlplane
10.0.1.11  worker1
10.0.1.12  worker2
EOF
kubectl completion bash >/etc/bash_completion.d/kubectl
crictl completion bash  >/etc/bash_completion.d/crictl 2>/dev/null || true

cat <<EOF

Golden image prepared.
  Kubernetes : $(kubeadm version -o short)
  CRI-O      : $(rpm -q --qf '%{VERSION}' cri-o)
  UEK R7     : ${UEK7} (default at next boot)

Next:
  1. reboot
  2. check: uname -r                     -> 5.15.0-... el9uek
            cat /sys/kernel/mm/transparent_hugepage/enabled  -> [madvise]
            cat /sys/devices/system/clocksource/clocksource0/current_clocksource
            systemctl is-active crio      -> active
  3. In VirtualBox, take a snapshot named 'pre-seal' (so you can fix things later)
  4. run 03-seal-golden.sh
EOF
