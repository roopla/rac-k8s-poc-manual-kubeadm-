# 15-pod-persistence.ps1
# Makes the RAC pods survive deletion and recreation. Grid's root scripts write startup files OUTSIDE
# /u01 (/etc/oracle, /etc/oratab, /etc/oraInst.loc, /etc/init.d/init.ohasd and ohasd, the
# oracle-ohasd systemd unit, /usr/local/bin/oraenv...), and only /u01 is on the worker's disk. A
# recreated pod would have an intact Grid home but no way to start Grid.
#
# What it does, per pod:
#   1. copies snapshot.sh and onstart.sh into /u01/app/restart-state
#   2. runs snapshot.sh: the files above, plus SSH host keys and the grid/oracle homes, into
#      /u01/app/restart-state/os-files.tgz (modes, setuid bits and owners kept)
#   3. checks the snapshot holds what Grid needs
# The image's setupContainerEnv.sh (rc.local, every pod start) calls onstart.sh. When the pod was
# recreated it runs the Oracle doc's "Complete Pod Restart Configuration Tasks" automatically:
# restores the home directories etc. from the snapshot (the doc's note), tfa_setup,
# rootcrs.sh -updateosfiles, crsctl start crs -wait. That needs the image built from the
# current rac-image\ files: .\10-rac-image-and-asm.ps1 -Rebuild -ImageOnly
#
#   .\15-pod-persistence.ps1            # install + snapshot both pods, then check
#   .\15-pod-persistence.ps1 -Check     # checks only
# Rerun after changing Grid or DB configuration, so the snapshot stays current.

param([switch]$Check)
. "$PSScriptRoot\lab-common.ps1"

$files = @("rac\restart-state\snapshot.sh", "rac\restart-state\onstart.sh") | ForEach-Object { Join-Path $Here $_ }

try {
    if (-not (Test-Ssh $CpPort)) { throw "controlplane not answering on port $CpPort" }
    if (-not $Check) {
        Say "1. Install the restart scripts and take a snapshot in each pod"
        Invoke-Remote $CpPort 'mkdir -p /root/rac/restart-state' -Quiet
        Copy-ToVm $CpPort $files "/root/rac/restart-state/"
        Invoke-Remote $CpPort @'
set -e
for p in racnode1-0 racnode2-0; do
  echo "--- $p"
  kubectl -n rac exec $p -- mkdir -p /u01/app/restart-state
  for f in snapshot.sh onstart.sh; do
    kubectl -n rac exec -i $p -- bash -c "cat > /u01/app/restart-state/$f && chmod 750 /u01/app/restart-state/$f" < /root/rac/restart-state/$f
  done
  kubectl -n rac exec $p -- bash /u01/app/restart-state/snapshot.sh
done
'@
        Ok "Snapshots taken"
    }

    Say "2. Checks"
    Invoke-Remote $CpPort @'
F=0
for p in racnode1-0 racnode2-0; do
  echo "--- $p"
  out=$(kubectl -n rac exec $p -- bash -c '
D=/u01/app/restart-state; f=0
[ -x $D/onstart.sh ] && echo "OK   onstart.sh in place" || { echo "FAIL onstart.sh missing"; f=1; }
[ -s $D/os-files.tgz ] && echo "OK   snapshot $(cat $D/snapshot.time)" || { echo "FAIL no snapshot"; f=1; }
for e in etc/oracle/ocr.loc etc/oracle/olr.loc etc/oratab etc/oraInst.loc etc/init.d/init.ohasd etc/init.d/ohasd etc/systemd/system/oracle-ohasd.service usr/local/bin/oraenv home/grid/.ssh/id_rsa home/oracle/.ssh/id_rsa; do
  grep -q " $e\$" $D/os-files.list 2>/dev/null && echo "OK   snapshot has /$e" || { echo "FAIL snapshot lacks /$e"; f=1; }
done
grep -q "^-rws.* etc/oracle/setasmgid$" $D/os-files.list && echo "OK   setasmgid keeps its setuid bit" || { echo "FAIL setasmgid setuid bit"; f=1; }
h=$(hostname); grep -q " etc/oracle/scls_scr/$h/" $D/os-files.list && echo "OK   scls_scr state for $h" || { echo "FAIL no scls_scr state for $h"; f=1; }
grep -q restart-state/onstart.sh /opt/scripts/startup/setupContainerEnv.sh && echo "OK   this pod'"'"'s image already calls the hook" || echo "INFO this pod runs the older image; a recreated pod uses the rebuilt one"
exit $f' 2>&1); rc=$?
  echo "$out"; [ $rc -eq 0 ] || F=1
done
exit $F
'@
    foreach ($w in $Workers) {
        Invoke-Remote $w.Port "f=0; podman run --rm --entrypoint /bin/grep localhost/oracle/database-rac:19-ol9-slim -q restart-state/onstart.sh /opt/scripts/startup/setupContainerEnv.sh && echo 'OK   $($w.Name): image on disk calls the restart hook' || { echo 'FAIL $($w.Name): image lacks the restart hook (run .\10-rac-image-and-asm.ps1 -Rebuild -ImageOnly)'; f=1; }; exit `$f"
    }
    Ok "Pods are ready for the restart test"
}
catch {
    Write-Host "`nSTOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Fix the cause and rerun .\15-pod-persistence.ps1" -ForegroundColor Yellow
    exit 1
}
