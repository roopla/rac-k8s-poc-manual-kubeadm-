# 13-grid-install.ps1
# Phase 9: Oracle Grid Infrastructure 19.32 (gold image) in the RAC pods, following the doc's
# "Deploy Oracle Grid Infrastructure in the Kubernetes Pods" with the gold-image changes:
# no -applyRU / -applyOneOffs, no OPatch swap.
#
# Long steps run DETACHED inside the pod (nohup), logging to /u01/poc-logs/<step>.log and writing
# their exit code to <step>.rc. This window just follows the log, so a dropped SSH session or a
# sleeping PC does not kill the install: rerun the script and it resumes where it was.
#
#   .\13-grid-install.ps1            # run or resume
#   .\13-grid-install.ps1 -Check     # only the final cluster checks
#
# Takes about 45-75 minutes on this lab (gridSetup ~15-25 min, root.sh ~10-20 min per node).

param([switch]$Check)
. "$PSScriptRoot\lab-common.ps1"

# Bash helpers for every remote block (runs on controlplane, talks to the pods with kubectl)
$Helpers = @'
P1=racnode1-0; P2=racnode2-0; L=/u01/poc-logs
K() { kubectl -n rac exec "$1" -- bash -c "$2"; }
# upload stdin as $L/<name>.sh inside a pod
put() { kubectl -n rac exec -i "$1" -- bash -c "mkdir -p $L && cat > $L/$2.sh && chmod 755 $L/$2.sh"; }
# start $L/<name>.sh detached, unless it is running (live PID in <name>.pid) or already finished.
# A step that finished with an error is only restarted when the 3rd argument is "retry".
start() { kubectl -n rac exec "$1" -- bash -c "cd $L; if [ -f $2.pid ] && [ ! -f $2.rc ] && kill -0 \$(cat $2.pid) 2>/dev/null; then exit 0; fi; if [ -f $2.rc ]; then r=\$(cat $2.rc); [ \"\$r\" = 0 ] || [ \"\$r\" = 6 ] && exit 0; [ '$3' = retry ] || exit 0; mv $2.log $2.log.failed-\$(date +%s); rm -f $2.rc; fi; nohup setsid bash -c 'echo \$\$ > $L/$2.pid; bash $L/$2.sh; echo \$? > $L/$2.rc' > $L/$2.log 2>&1 < /dev/null &"; }
# follow the log until the step writes its rc; return that rc
follow() {
  local pod=$1 name=$2 seen=0 out rc
  while :; do
    rc=$(kubectl -n rac exec "$pod" -- cat $L/$name.rc 2>/dev/null)
    out=$(kubectl -n rac exec "$pod" -- bash -c "tail -n +$((seen + 1)) $L/$name.log 2>/dev/null")
    if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/      /'; seen=$((seen + $(printf '%s\n' "$out" | wc -l))); fi
    [ -n "$rc" ] && return $rc
    sleep 15
  done
}
done_ok() { local rc; rc=$(kubectl -n rac exec "$1" -- cat $L/$2.rc 2>/dev/null); [ "$rc" = 0 ] || [ "$rc" = 6 ]; }
'@

# Stream a remote bash block live (no capture), so long steps show progress as they happen
function Invoke-Live([string]$body) {
    ($Helpers + "`n" + $body) | ssh -p $CpPort @SshBase -o BatchMode=yes root@127.0.0.1 "tr -d '\r' | bash -s"
    if ($LASTEXITCODE -ne 0) { throw "Step failed (exit $LASTEXITCODE). See the output above; rerun to resume." }
}
function Step-Done([string]$pod, [string]$name) {
    $r = Get-Remote $CpPort ($Helpers + "`ndone_ok $pod $name && echo yes")
    return ($r -contains "yes")
}

try {
    if (-not (Test-Ssh $CpPort)) { throw "controlplane not answering on port $CpPort" }
    $state = "$(Get-Remote $CpPort "kubectl -n rac get pod racnode1-0 racnode2-0 -o jsonpath='{.items[*].status.phase}'")".Trim()
    if ($state -ne "Running Running") { throw "RAC pods are not both Running ($state). Run .\12-rac-pods.ps1 first." }

    if (-not $Check) {
    # ================================================================ 1. users, SSH, directories
    Say "1. Grid and oracle users: SSH keys, known_hosts, directories, profiles (both pods)"
    Invoke-Live @'
set -e
for p in $P1 $P2; do
  K $p '
set -e
for u in grid oracle; do
  h=/home/$u; mkdir -p $h/.ssh; chmod 700 $h/.ssh
  cat /mnt/.ssh/id_rsa > $h/.ssh/id_rsa; cat /mnt/.ssh/id_rsa.pub > $h/.ssh/id_rsa.pub
  cat /mnt/.ssh/id_rsa.pub > $h/.ssh/authorized_keys
  chmod 400 $h/.ssh/id_rsa; chmod 600 $h/.ssh/authorized_keys
  chown -R $u:oinstall $h/.ssh
done
mkdir -p /u01/app/19c/grid /u01/app/grid /u01/app/oraInventory /u01/app/oracle /u01/app/oracle/product/19c/dbhome_1 /u01/poc-logs
# The doc sets ownership/permissions recursively on the EMPTY tree. Never repeat that once a home
# has been unzipped: it strips setuid bits and root ownership that gridSetup/root.sh set
# (seen here: ORA-12547 for oracle -> ASM, DBCA DBT-05801). Fix with rootcrs.sh -init if it happens.
if [ -z "$(ls -A /u01/app/19c/grid)" ] && [ -z "$(ls -A /u01/app/oracle/product/19c/dbhome_1)" ]; then
  chown -R grid:oinstall /u01/app; chown -R oracle:oinstall /u01/app/oracle; chmod -R 775 /u01/app
else
  echo "  homes already present: ownership/permissions left as installed"
fi
chown grid:oinstall /u01/poc-logs; chmod 775 /u01/poc-logs
if [ -d /stage ]; then chown grid:oinstall /stage; chmod 775 /stage; fi
add() { grep -qxF "$2" /home/$1/.bashrc || echo "$2" >> /home/$1/.bashrc; }
add grid "export TMPDIR=/var/tmp"; add grid "export ORACLE_HOME=/u01/app/19c/grid"; add grid "export PATH=\$ORACLE_HOME/bin:\$PATH"
add oracle "export TMPDIR=/var/tmp"; add oracle "export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1"; add oracle "export PATH=\$ORACLE_HOME/bin:\$PATH"
'
  echo "  $p: keys, directories and profiles set"
done
# known_hosts after both pods have their keys in place. The doc's hashed entries (-H), plus plain
# ones: cluvfy looks for plain host names and otherwise reports PRVH-1526 / PRVF-4009 and skips the node.
for p in $P1 $P2; do
  K $p 'for u in grid oracle; do su - $u -c "rm -f ~/.ssh/known_hosts; ssh-keyscan -H racnode1-0 racnode2-0 >> ~/.ssh/known_hosts 2>/dev/null; ssh-keyscan racnode1-0 racnode2-0 >> ~/.ssh/known_hosts 2>/dev/null"; done'
done
set +e
f=0
for p in $P1 $P2; do for u in grid oracle; do for t in racnode1-0 racnode2-0; do
  r=$(K $p "su - $u -c 'ssh -o BatchMode=yes -o ConnectTimeout=5 $u@$t echo ok' 2>&1") || true
  [ "$r" = ok ] && echo "  OK   $p: $u -> $t" || { echo "  FAIL $p: $u -> $t: $r"; f=1; }
done; done; done
exit $f
'@
    Ok "Passwordless SSH works for grid and oracle in every direction"

    # ================================================================ 2. unzip the Grid gold image
    Say "2. Unzip oracle-gridhome-19.32.zip into /u01/app/19c/grid on racnode1-0 (5-10 minutes)"
    Invoke-Live @'
put $P1 unzip-grid <<'EOS'
set -e
GH=/u01/app/19c/grid
if [ ! -x $GH/gridSetup.sh ]; then
  su - grid -c "unzip -K -q -o /stage/oracle-gridhome-19.32.zip -d $GH"
fi
# doc: cvu_config CV_DESTLOC, and comment out SWAP_SPACE in oraparam.ini (pods have no swap)
grep -q '^CV_DESTLOC=' $GH/cv/admin/cvu_config || echo 'CV_DESTLOC=/var/tmp' >> $GH/cv/admin/cvu_config
sed -i 's/^SWAP_SPACE=/#SWAP_SPACE=/' $GH/oui/oraparam.ini
chown grid:oinstall $GH/cv/admin/cvu_config $GH/oui/oraparam.ini
ls -ld $GH; du -sh $GH
# (no opatch here: an unzipped gold image is not in an inventory until gridSetup.sh registers it;
#  the patch list is checked in step 7)
ls $GH/gridSetup.sh $GH/root.sh 2>/dev/null; test -x $GH/gridSetup.sh
# The 19.32 gold image stores bin/oracle as a 0-byte placeholder and no setuid bits: the installer
# links bin/oracle and root.sh sets owners and setuid bits. So 0 here is expected; the real check
# (bin/oracle -rwsr-s--x, count > 0) runs after root.sh. Without it, non-owner connections fail
# with ORA-12547 (DBCA: DBT-05801).
ls -l $GH/bin/oracle; echo "setuid/setgid files in $GH/bin after unzip: $(find $GH/bin -perm /6000 -type f | wc -l) (0 is expected)"
EOS
start $P1 unzip-grid retry
follow $P1 unzip-grid
'@
    Ok "Grid home unzipped"

    # ================================================================ 3. response file
    $hasPw = (Get-Remote $CpPort "kubectl -n rac exec racnode1-0 -- bash -c 'grep -q ^oracle.install.asm.SYSASMPassword=. /u01/poc-logs/gi.rsp 2>/dev/null && echo yes'") -contains "yes"
    if (-not $hasPw -and -not (Step-Done "racnode1-0" "configtools")) {
        Say "3. Grid response file"
        Write-Host "  The SYSASM / ASMSNMP password goes only into /u01/poc-logs/gi.rsp inside racnode1-0"
        Write-Host "  (mode 600, owner grid) and is blanked after the install."
        Write-Host "  Rules: 8-30 characters, starts with a letter, letters and digits only, at least one"
        Write-Host "  upper-case letter, one lower-case letter and one digit."
        do {
            $s1 = Read-Host "  Password" -AsSecureString
            $s2 = Read-Host "  Again" -AsSecureString
            $pw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1))
            $pw2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2))
            $good = ($pw -ceq $pw2) -and ($pw -cmatch '^[A-Za-z][A-Za-z0-9]{7,29}$') -and ($pw -cmatch '[A-Z]') -and ($pw -cmatch '[a-z]') -and ($pw -match '[0-9]')
            if (-not $good) { Warn "Passwords differ or break the rules above; try again." }
        } until ($good)
        $tpl = (Get-Content (Join-Path $Here "rac\gi.rsp.template") -Raw).Replace("`r`n", "`n").Replace("__PASSWORD__", $pw)
        $pw = $null; $pw2 = $null
        $tpl | ssh -p $CpPort @SshBase -o BatchMode=yes root@127.0.0.1 "kubectl -n rac exec -i racnode1-0 -- bash -c 'umask 077; tr -d \\015 > /u01/poc-logs/gi.rsp; chown grid:oinstall /u01/poc-logs/gi.rsp; grep -c = /u01/poc-logs/gi.rsp'"
        if ($LASTEXITCODE -ne 0) { throw "Could not write gi.rsp into racnode1-0" }
        $tpl = $null
        Ok "gi.rsp written in racnode1-0"
    }

    # ================================================================ 4. gridSetup.sh
    Say "4. gridSetup.sh -silent on racnode1-0 (15-25 minutes; copies the home to racnode2-0)"
    Invoke-Live @'
put $P1 gridsetup <<'EOS'
# netmasks on the command line, exactly as the doc does (not valid inside the response file)
sed -i '/^oracle.install.crs.config.netmaskList=/d' /u01/poc-logs/gi.rsp
su - grid -c "/u01/app/19c/grid/gridSetup.sh -silent -waitforcompletion -responseFile /u01/poc-logs/gi.rsp oracle.install.crs.config.netmaskList=eth0:255.255.0.0,eth1:255.255.255.0,eth2:255.255.255.0"
EOS
start $P1 gridsetup
rc=0; follow $P1 gridsetup || rc=$?
case $rc in
  0) echo "  gridSetup.sh: success" ;;
  6) echo "  gridSetup.sh: success with warnings (exit 6), continuing" ;;
  *) echo "  gridSetup.sh failed (exit $rc). Fix the cause, then remove /u01/poc-logs/gridsetup.rc in racnode1-0 and rerun."; exit 1 ;;
esac
'@
    Ok "Grid software installed on both pods"

    # ================================================================ 5. root scripts
    Say "5. Root scripts: orainstRoot.sh on both, then root.sh on racnode1-0 then racnode2-0 (20-40 minutes)"
    Invoke-Live @'
for p in $P1 $P2; do
  printf '/u01/app/oraInventory/orainstRoot.sh\n' | put $p orainstroot
  start $p orainstroot retry; echo "  -- $p orainstRoot.sh"; follow $p orainstroot || { echo "  orainstRoot.sh failed on $p"; exit 1; }
done
for p in $P1 $P2; do
  printf '/u01/app/19c/grid/root.sh\nrc=$?\ntail -60 $(ls -t /u01/app/19c/grid/install/root_*.log | head -1)\nexit $rc\n' | put $p rootsh
  start $p rootsh; echo "  -- $p root.sh (log follows when it finishes writing)"
  follow $p rootsh || { echo "  root.sh failed on $p. See the log above; fix, remove /u01/poc-logs/rootsh.rc in $p and rerun."; exit 1; }
done
for p in $P1 $P2; do
  n=$(K $p "find /u01/app/19c/grid/bin -perm /6000 -type f | wc -l" | tr -dc 0-9); K $p "ls -l /u01/app/19c/grid/bin/oracle" | sed "s/^/  $p /"
  [ "${n:-0}" -gt 0 ] || { echo "  ERROR: no setuid/setgid files in /u01/app/19c/grid/bin on $p after root.sh (ORA-12547 later). Stop here."; exit 1; }
done
'@
    Ok "root.sh completed on both pods"

    # ================================================================ 6. config tools
    Say "6. gridSetup.sh -executeConfigTools on racnode1-0 (5-10 minutes)"
    Invoke-Live @'
put $P1 configtools <<'EOS'
su - grid -c "/u01/app/19c/grid/gridSetup.sh -executeConfigTools -responseFile /u01/poc-logs/gi.rsp -silent"
EOS
start $P1 configtools retry
rc=0; follow $P1 configtools || rc=$?
if [ "$rc" != 0 ] && [ "$rc" != 6 ]; then
  # Which assistants failed? If it is only the CVU post-check, that is a container-environment
  # finding (e.g. PRVF-4009 user equivalence by IP/FQDN), not a broken cluster: carry on.
  failed=$(K $P1 'f=$(ls -t /u01/app/oraInventory/logs/GridSetupActions*/gridSetupActions*.log | head -1); grep -oE "\] [A-Za-z ]+ failed\." "$f" | sed -E "s/^\] //; s/ failed\.$//" | sort -u')
  echo "  failed assistants: ${failed:-unknown}"
  if [ "$failed" = "Oracle Cluster Verification Utility" ]; then
    echo "  only the CVU post-check failed; netca and asmca completed. Treated as a warning."
    K $P1 'f=$(ls -t /u01/app/oraInventory/logs/GridSetupActions*/gridSetupActions*.log | head -1); grep -oE "PRV[A-Z]-[0-9]+ : [^.]*" "$f" | sort -u | sed "s/^/    /"'
    K $P1 "echo 6 > $L/configtools.rc"; rc=6
  fi
fi
case $rc in
  0|6) echo "  config tools done (exit $rc)"
       # blank the passwords now that nothing needs them
       K $P1 "sed -i -E 's/^(oracle.install.asm.(SYSASM|monitor)Password)=.*/\1=/' $L/gi.rsp; echo '  passwords blanked in gi.rsp'" ;;
  *)   echo "  config tools failed (exit $rc); passwords kept in gi.rsp so a rerun can retry"; exit 1 ;;
esac
'@
    Ok "Configuration complete"
    }

    # ================================================================ 7. checks
    Say "7. Cluster checks"
    Invoke-Live @'
G() { K $P1 "su - grid -c '$1'"; }
echo "---- crsctl check cluster -all";      G 'crsctl check cluster -all'
echo "---- olsnodes -n -s -t";              G 'olsnodes -n -s -t'
echo "---- crsctl stat res -t";             G 'crsctl stat res -t'
echo "---- crsctl stat res -init -t";       G 'crsctl stat res -init -t'
echo "---- oifcfg getif";                   G 'oifcfg getif'
echo "---- srvctl config scan";             G 'srvctl config scan'
echo "---- asmcmd lsdg";                    G 'export ORACLE_SID=+ASM1; asmcmd lsdg'
echo "---- opatch lspatches";               G '$ORACLE_HOME/OPatch/opatch lspatches'
f=0
G 'crsctl check cluster -all' | grep -q 'CRS-4537' || { echo "FAIL Cluster Ready Services not online"; f=1; }
n=$(G 'olsnodes -s' | grep -c Active); [ "$n" -eq 2 ] && echo "OK   2 nodes Active" || { echo "FAIL $n nodes Active"; f=1; }
G 'crsctl stat res -init -t' | grep -A1 'ora.cluster_interconnect.haip' | grep -q ONLINE && echo "OK   HAIP online" || { echo "FAIL HAIP not online"; f=1; }
G 'crsctl stat res ora.DATA.dg -t' | grep -c ONLINE | awk '{ if ($1 >= 2) print "OK   DATA disk group online on both nodes"; else { print "FAIL DATA disk group"; exit 1 } }' || f=1
echo "INFO ctssd mode: $(G 'crsctl check ctss' | tail -1)"
exit $f
'@
    Ok "Grid Infrastructure is up on both RAC pods"
    Say "Next"
    Info "Phase 10: database software from oracle-dbhome-19.32.zip, then dbca (with the 34436514 memory check)."
}
catch {
    Write-Host "`nSTOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Rerun .\13-grid-install.ps1 to resume; finished steps are skipped." -ForegroundColor Yellow
    exit 1
}
