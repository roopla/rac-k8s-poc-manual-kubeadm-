#!/bin/bash
# snapshot.sh - saves every file that Grid/DB root scripts wrote OUTSIDE /u01 into /u01, which is the
# worker's disk and survives pod deletion. Without them a recreated pod has an intact Grid home but no
# startup service and no registry pointers, so Grid never starts. Run as root in each RAC pod after
# the Grid and DB installs, and again after changing Grid or DB configuration on that node.
#   bash /u01/app/restart-state/snapshot.sh [--force]
# The previous snapshot is kept as os-files.tgz.prev.
set -euo pipefail
D=/u01/app/restart-state
mkdir -p $D
cd /
paths=(
  etc/oracle                      # ocr.loc, olr.loc, scls_scr (per-node start state), setasmgid
  etc/oratab etc/oraInst.loc
  etc/init.d/init.ohasd etc/init.d/ohasd
  usr/local/bin/dbhome usr/local/bin/oraenv usr/local/bin/coraenv
  home/grid home/oracle           # SSH keys, known_hosts, profiles
)
paths+=( $(cd / && ls -d etc/ssh/ssh_host_* 2>/dev/null || true) )                 # same host keys = known_hosts stays valid
paths+=( $(cd / && find etc/systemd -name 'oracle-ohasd*' 2>/dev/null) )    # unit + its enable symlink
keep=(); for p in "${paths[@]}"; do [ -e "/$p" ] || [ -L "/$p" ] && keep+=("$p") || echo "  (not present: /$p)"; done
# Refuse to replace a good snapshot with an incomplete one (for example after a manual restart that
# did not recreate /etc/oratab or /etc/oraInst.loc). --force overrides.
need=(etc/oracle/ocr.loc etc/oracle/olr.loc etc/oratab etc/oraInst.loc etc/init.d/init.ohasd
      etc/systemd/system/oracle-ohasd.service usr/local/bin/oraenv home/grid/.ssh/id_rsa home/oracle/.ssh/id_rsa)
miss=(); for n in "${need[@]}"; do [ -e "/$n" ] || miss+=("/$n"); done
if [ ${#miss[@]} -gt 0 ] && [ "${1:-}" != "--force" ]; then
  echo "ERROR: required files missing: ${miss[*]}"
  echo "       existing snapshot kept ($(cat $D/snapshot.time 2>/dev/null || echo none)). Fix the files, or rerun with --force."
  exit 1
fi
tmp=$D/os-files.tgz.new
# -p keeps modes incl. setuid (setasmgid); --numeric-owner because the image fixes the UIDs/GIDs.
# Sockets and runtime files under /etc/oracle/maps are skipped by tar or harmless.
tar --numeric-owner -czpf $tmp --warning=no-file-ignored --exclude='etc/oracle/maps/*' "${keep[@]}"
if [ -f $D/os-files.tgz ]; then cp -p $D/os-files.tgz $D/os-files.tgz.prev; cp -p $D/os-files.list $D/os-files.list.prev 2>/dev/null || true; fi
mv -f $tmp $D/os-files.tgz
tar -tzvf $D/os-files.tgz | awk '{print $1, $2, $6}' > $D/os-files.list
date -Is > $D/snapshot.time
echo "snapshot: $(wc -l < $D/os-files.list) entries in $D/os-files.tgz ($(du -h $D/os-files.tgz | cut -f1)), $(cat $D/snapshot.time)"
