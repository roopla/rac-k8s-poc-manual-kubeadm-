#!/bin/bash
# onstart.sh - the Oracle doc's "Complete Pod Restart Configuration Tasks", run automatically.
# Called by the image's setupContainerEnv.sh (rc.local) at every pod start. Kept on /u01, not in the
# image, so it can change without an image rebuild. Does nothing unless the pod was recreated
# (Grid's oracle-ohasd service missing). Log: /u01/app/restart-state/onstart.log
#   0. restore the grid/oracle home directories and other root-filesystem files from the snapshot
#      (the doc's note: back these up under /u01 instead of redoing SSH keys and .bashrc by hand);
#      Grid's own OS files are NOT restored from the copy, Grid regenerates them in step 2
#   1. doc step 1: tfa_setup            (failure logged, not fatal: TFA is diagnostics only)
#   2. doc step 2: rootcrs.sh -updateosfiles   (fallback: the copy in the snapshot)
#   3. doc step 3: crsctl start crs -wait
#   4. doc step 4: crsctl stat res -t into the log
D=/u01/app/restart-state
G=/u01/app/19c/grid
log=$D/onstart.log
if [ "$1" != "--run" ]; then
  # rc.local must not wait 5-10 minutes for Grid: start the real work detached and return
  [ -f /etc/systemd/system/oracle-ohasd.service ] && { echo "=== $(date -Is) $(hostname): Grid startup files present, nothing to do" >> $log; exit 0; }
  setsid nohup "$0" --run >> $log 2>&1 < /dev/null &
  exit 0
fi
echo "=== $(date -Is) $(hostname): pod was recreated, running the restart tasks"
if [ ! -s $D/os-files.tgz ]; then
  echo "no snapshot in $D: run snapshot.sh after the install. Stopping; do the doc's steps by hand."
  exit 1
fi
echo "--- 0. restore home directories and root-filesystem files (snapshot $(cat $D/snapshot.time))"
tar --numeric-owner -xzpf $D/os-files.tgz -C / \
    --exclude='etc/oracle' --exclude='etc/oracle/*' --exclude='etc/init.d/*ohasd' --exclude='etc/systemd/*'
systemctl restart sshd && echo "sshd restarted with the pod's original host keys"
echo "--- 1. doc step 1: tfa_setup"
$G/crs/install/tfa_setup -silent -crshome $G || echo "WARN tfa_setup failed (diagnostics only; Grid does not need it)"
echo "--- 2. doc step 2: rootcrs.sh -updateosfiles"
if ! $G/crs/install/rootcrs.sh -updateosfiles || [ ! -f /etc/systemd/system/oracle-ohasd.service ]; then
  echo "WARN -updateosfiles failed: restoring Grid's OS files from the snapshot instead"
  tar --numeric-owner -xzpf $D/os-files.tgz -C / etc/oracle etc/init.d $(tar -tzf $D/os-files.tgz | grep '^etc/systemd/.*oracle-ohasd')
  systemctl daemon-reload; systemctl enable oracle-ohasd.service
fi
ls -l /etc/oracle
echo "--- 3. doc step 3: crsctl start crs -wait"
$G/bin/crsctl start crs -wait
echo "--- 4. doc step 4: status"
$G/bin/crsctl stat res -t
echo "=== $(date -Is) restart tasks finished"
