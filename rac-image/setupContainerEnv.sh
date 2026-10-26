#!/bin/bash
# setupContainerEnv.sh - runs from /etc/rc.d/rc.local at every RAC pod start (systemd is PID 1).
# Same job as the Oracle doc's script: hand the ASM block devices to grid:asmadmin, and stop
# dnf-makecache from running inside the pod. Added for this PoC: if /u01 holds the restart hook,
# run it, so a recreated pod gets back the Grid files that live outside /u01 and starts Grid.
for d in /dev/asm-disk*; do
  [ -b "$d" ] || continue
  chown grid:asmadmin "$d"
  chmod 660 "$d"
done
systemctl disable --now dnf-makecache.timer dnf-makecache.service >/dev/null 2>&1
systemctl reset-failed
[ -x /u01/app/restart-state/onstart.sh ] && /u01/app/restart-state/onstart.sh
exit 0
