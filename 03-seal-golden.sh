#!/usr/bin/env bash
# 03-seal-golden.sh
# Run as root on the golden VM as the LAST step before cloning. Powers the VM off.
# Removes per-machine identity so every clone gets its own:
#   machine-id (regenerated at first boot), SSH host keys (sshd-keygen regenerates them),
#   logs, caches and shell history.
# VirtualBox gives each full clone a new hardware UUID (kubeadm's product_uuid) and new MACs.

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

dnf clean all
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -rf /tmp/* /var/tmp/*
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
rm -f /root/.bash_history
history -c || true

echo "Golden image sealed. Powering off. Do NOT boot it again before cloning."
sleep 3
poweroff
