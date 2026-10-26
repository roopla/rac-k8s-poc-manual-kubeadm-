# 14-db-install.ps1
# Phase 10: Oracle RAC database 19.32 (gold image) in the RAC pods, following the doc's
# "Deploy Oracle RAC Database in the Pods" with the gold-image changes (no -applyRU / -applyOneOffs,
# no OPatch swap). Same detached, resumable design as 13-grid-install.ps1.
#
#   .\14-db-install.ps1            # run or resume (asks for the SYS/SYSTEM/PDBADMIN password once)
#   .\14-db-install.ps1 -Check     # only the final checks
#
# Takes about 45-90 minutes on this lab (runInstaller ~10-20 min, dbca ~30-60 min).

param([switch]$Check)
. "$PSScriptRoot\lab-common.ps1"

$OH = "/u01/app/oracle/product/19c/dbhome_1"

$Helpers = @'
P1=racnode1-0; P2=racnode2-0; L=/u01/poc-logs; OH=/u01/app/oracle/product/19c/dbhome_1
K() { kubectl -n rac exec "$1" -- bash -c "$2"; }
put() { kubectl -n rac exec -i "$1" -- bash -c "mkdir -p $L && cat > $L/$2.sh && chmod 700 $L/$2.sh"; }
start() { kubectl -n rac exec "$1" -- bash -c "cd $L; if [ -f $2.pid ] && [ ! -f $2.rc ] && kill -0 \$(cat $2.pid) 2>/dev/null; then exit 0; fi; if [ -f $2.rc ]; then r=\$(cat $2.rc); [ \"\$r\" = 0 ] || [ \"\$r\" = 6 ] && exit 0; [ '$3' = retry ] || exit 0; mv $2.log $2.log.failed-\$(date +%s); rm -f $2.rc; fi; nohup setsid bash -c 'echo \$\$ > $L/$2.pid; bash $L/$2.sh; echo \$? > $L/$2.rc' > $L/$2.log 2>&1 < /dev/null &"; }
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

function Invoke-Live([string]$body) {
    ($Helpers + "`n" + $body) | ssh -p $CpPort @SshBase -o BatchMode=yes root@127.0.0.1 "tr -d '\r' | bash -s"
    if ($LASTEXITCODE -ne 0) { throw "Step failed (exit $LASTEXITCODE). See the output above; rerun to resume." }
}
function Step-Done([string]$pod, [string]$name) {
    return ((Get-Remote $CpPort ($Helpers + "`ndone_ok $pod $name && echo yes")) -contains "yes")
}

try {
    if (-not (Test-Ssh $CpPort)) { throw "controlplane not answering on port $CpPort" }
    $crs = Get-Remote $CpPort "kubectl -n rac exec racnode1-0 -- su - grid -c 'crsctl check cluster -all' 2>/dev/null | grep -c CRS-4537"
    if ("$crs".Trim() -ne "2") { throw "Grid is not online on both nodes. Run .\13-grid-install.ps1 (or -Check) first." }

    if (-not $Check) {
    # ================================================================ 0. password (asked up front so the rest runs unattended)
    $dbcaDone = Step-Done "racnode1-0" "dbca"
    $pwFile = (Get-Remote $CpPort "kubectl -n rac exec racnode1-0 -- bash -c 'test -s /u01/poc-logs/db.pw && echo yes'") -contains "yes"
    if (-not $dbcaDone -and -not $pwFile) {
        Say "0. Database password (SYS, SYSTEM and the PDB admin)"
        Write-Host "  Stored only in /u01/poc-logs/db.pw inside racnode1-0 (mode 600, root) and deleted after dbca."
        Write-Host "  Rules: 8-30 characters, starts with a letter, letters and digits only, at least one"
        Write-Host "  upper-case letter, one lower-case letter and one digit. Can be the same as the Grid one."
        do {
            $s1 = Read-Host "  Password" -AsSecureString
            $s2 = Read-Host "  Again" -AsSecureString
            $pw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1))
            $pw2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2))
            $good = ($pw -ceq $pw2) -and ($pw -cmatch '^[A-Za-z][A-Za-z0-9]{7,29}$') -and ($pw -cmatch '[A-Z]') -and ($pw -cmatch '[a-z]') -and ($pw -match '[0-9]')
            if (-not $good) { Warn "Passwords differ or break the rules above; try again." }
        } until ($good)
        $pw | ssh -p $CpPort @SshBase -o BatchMode=yes root@127.0.0.1 "kubectl -n rac exec -i racnode1-0 -- bash -c 'umask 077; tr -d \\015 > /u01/poc-logs/db.pw; wc -l < /u01/poc-logs/db.pw'"
        if ($LASTEXITCODE -ne 0) { throw "Could not store the password in racnode1-0" }
        $pw = $null; $pw2 = $null
        Ok "Password stored in racnode1-0"
    }

    # ================================================================ 1. unzip the DB gold image
    Say "1. Unzip oracle-dbhome-19.32.zip into $OH on racnode1-0 (5-10 minutes)"
    Invoke-Live @'
put $P1 unzip-db <<'EOS'
set -e
OH=/u01/app/oracle/product/19c/dbhome_1
if [ ! -x $OH/runInstaller ]; then
  su - oracle -c "unzip -K -q -o /stage/oracle-dbhome-19.32.zip -d $OH"
fi
sed -i 's/^SWAP_SPACE=/#SWAP_SPACE=/' $OH/oui/oraparam.ini      # doc: pods have no swap
chown oracle:oinstall $OH/oui/oraparam.ini
du -sh $OH; ls $OH/runInstaller $OH/root.sh; test -x $OH/runInstaller
# The 19.32 gold image stores bin/oracle as a 0-byte placeholder and no setuid bits: the installer
# links bin/oracle and root.sh sets owners and setuid bits. So 0 here is expected; the real check
# (bin/oracle -rwsr-s--x, count > 0) runs after root.sh. Without it, non-owner connections fail
# with ORA-12547 (DBCA: DBT-05801).
ls -l $OH/bin/oracle; echo "setuid/setgid files in $OH/bin after unzip: $(find $OH/bin -perm /6000 -type f | wc -l) (0 is expected)"
EOS
start $P1 unzip-db retry
follow $P1 unzip-db
'@
    Ok "DB home unzipped"

    # ================================================================ 2. runInstaller (software only)
    Say "2. runInstaller -silent INSTALL_DB_SWONLY on racnode1-0 (10-20 minutes; copies the home to racnode2-0)"
    Invoke-Live @'
put $P1 runinstaller <<'EOS'
OH=/u01/app/oracle/product/19c/dbhome_1
su - oracle -c "$OH/runInstaller -waitforcompletion -silent \
 oracle.install.option=INSTALL_DB_SWONLY ORACLE_HOSTNAME=racnode1-0 UNIX_GROUP_NAME=oinstall \
 oracle.install.db.CLUSTER_NODES=racnode1-0,racnode2-0 INVENTORY_LOCATION=/u01/app/oraInventory \
 SELECTED_LANGUAGES=en ORACLE_HOME=$OH ORACLE_BASE=/u01/app/oracle oracle.install.db.InstallEdition=EE \
 oracle.install.db.OSDBA_GROUP=dba oracle.install.db.OSBACKUPDBA_GROUP=backupdba oracle.install.db.OSDGDBA_GROUP=dgdba \
 oracle.install.db.OSKMDBA_GROUP=kmdba oracle.install.db.OSRACDBA_GROUP=racdba \
 SECURITY_UPDATES_VIA_MYORACLESUPPORT=false DECLINE_SECURITY_UPDATES=true"
EOS
start $P1 runinstaller
rc=0; follow $P1 runinstaller || rc=$?
case $rc in
  0) echo "  runInstaller: success" ;;
  6) echo "  runInstaller: success with warnings (exit 6), continuing" ;;
  *) echo "  runInstaller failed (exit $rc). Fix the cause, remove /u01/poc-logs/runinstaller.rc in racnode1-0 and rerun."; exit 1 ;;
esac
'@
    Ok "DB software installed on both pods"

    # ================================================================ 3. root.sh for the DB home
    Say "3. DB home root.sh on racnode1-0 and racnode2-0 (1-2 minutes)"
    Invoke-Live @'
for p in $P1 $P2; do
  printf '/u01/app/oracle/product/19c/dbhome_1/root.sh\n' | put $p rootsh-db
  start $p rootsh-db retry; echo "  -- $p"
  follow $p rootsh-db || { echo "  DB root.sh failed on $p"; exit 1; }
done
for p in $P1 $P2; do
  n=$(K $p "find /u01/app/oracle/product/19c/dbhome_1/bin -perm /6000 -type f | wc -l" | tr -dc 0-9); K $p "ls -l /u01/app/oracle/product/19c/dbhome_1/bin/oracle" | sed "s/^/  $p /"
  [ "${n:-0}" -gt 0 ] || { echo "  ERROR: no setuid/setgid files in /u01/app/oracle/product/19c/dbhome_1/bin on $p after root.sh (ORA-12547 later). Stop here."; exit 1; }
done
K $P1 "su - oracle -c '\$ORACLE_HOME/OPatch/opatch lspatches'" | sed 's/^/  /'
'@
    Ok "DB home registered on both pods"

    # ================================================================ 4. dbca
    Say "4. dbca -createDatabase ORCLCDB (RAC, ASM +DATA, 1 PDB) on racnode1-0 (30-60 minutes)"
    Invoke-Live @'
put $P1 dbca <<'EOS'
set -e
OH=/u01/app/oracle/product/19c/dbhome_1
test -s /u01/poc-logs/db.pw || { echo "no password in /u01/poc-logs/db.pw"; exit 2; }
PW=$(cat /u01/poc-logs/db.pw)
# The doc's dbca command, except for the password variable and memory. The doc's -memoryPercentage 30
# needs fix 34436514, which is NOT in the 19.32 gold image: on this PoC's first run DBCA sized memory
# from the 22 GB worker (SGA+PGA 6498 MB) instead of the 12 GiB pod. -totalMemory 3600 is 30% of the
# pod, and the SGA then fits in the pod's 4 GiB of hugepages.
su - oracle -c "$OH/bin/dbca -silent -createDatabase \
 -templateName General_Purpose.dbc -gdbname ORCLCDB -createAsContainerDatabase true \
 -sysPassword $PW -systemPassword $PW -datafileDestination +DATA -storageType ASM \
 -characterSet AL32UTF8 -redoLogFileSize 1024 -databaseType OLTP -databaseConfigType RAC \
 -nodelist racnode1-0,racnode2-0 -useOMF true -numberOfPDBs 1 -pdbAdminPassword $PW \
 -pdbName ORCLPDB -totalMemory 3600"
EOS
start $P1 dbca
rc=0; follow $P1 dbca || rc=$?
case $rc in
  0|6) echo "  dbca finished (exit $rc)"
       K $P1 "rm -f $L/db.pw; echo '  password file deleted'" ;;
  *)   echo "  dbca failed (exit $rc). Logs: /u01/app/oracle/cfgtoollogs/dbca/ORCLCDB in racnode1-0."
       echo "  Fix the cause, drop any half-built database, remove /u01/poc-logs/dbca.rc and rerun."; exit 1 ;;
esac
'@
    Ok "Database ORCLCDB created"

    # ================================================================ 5. application service (doc step 11)
    Say "5. Service ORCLPDBSVC on both instances"
    Invoke-Live @'
K $P1 "su - oracle -c 'srvctl config service -d ORCLCDB -s ORCLPDBSVC >/dev/null 2>&1 || srvctl add service -d ORCLCDB -pdb ORCLPDB -service ORCLPDBSVC -notification true -preferred ORCLCDB1,ORCLCDB2; srvctl start service -d ORCLCDB -s ORCLPDBSVC 2>/dev/null; srvctl status service -d ORCLCDB'"
'@
    Ok "Service in place"
    }

    # ================================================================ 6. checks
    Say "6. Database checks"
    Invoke-Live @'
put $P1 dbcheck <<'EOS'
su - oracle -c "srvctl status database -d ORCLCDB -verbose"
su - oracle -c "srvctl status service -d ORCLCDB"
su - oracle -c "export ORACLE_SID=ORCLCDB1; sqlplus -s / as sysdba" <<'SQL'
set lines 200 pages 100 feed off
col name for a24
col value for a30
prompt ---- instances
select inst_id, instance_name, host_name, status from gv$instance order by 1;
prompt ---- PDBs
select inst_id, name, open_mode from gv$pdbs order by 1, 2;
prompt ---- memory (MB) and large pages
select name, case when name in ('use_large_pages','memory_target') then value else to_char(round(value/1024/1024)) end value
  from v$parameter where name in ('sga_target','pga_aggregate_target','memory_target','use_large_pages') order by name;
prompt ---- SGA + PGA total
select 'POC_MEM '||round((select value from v$parameter where name='sga_target')/1024/1024
                    + (select value from v$parameter where name='pga_aggregate_target')/1024/1024) from dual;
select 'POC_SGA '||round(value/1024/1024) from v$parameter where name='sga_target';
prompt ---- SQL patches per container (cdb_ views leave out PDB$SEED)
col description for a55
select con_id, patch_id, action, status, description from cdb_registry_sqlpatch order by con_id, action_time;
select 'POC_SQLPATCH_OK '||count(*) from cdb_registry_sqlpatch where status='SUCCESS';
prompt ---- unresolved PDB plug-in violations
col cause for a12
col message for a60
select name, cause, status, substr(message,1,60) message from pdb_plug_in_violations where status <> 'RESOLVED';
select 'POC_VIOL '||count(*) from pdb_plug_in_violations where status <> 'RESOLVED';
SQL
EOS
K $P1 "bash $L/dbcheck.sh" | tee /tmp/dbcheck.out
f=0
n=$(grep -c 'is running on node' /tmp/dbcheck.out); [ "$n" -ge 2 ] && echo "OK   both instances running" || { echo "FAIL instances running: $n"; f=1; }
grep -q 'Instance status: Open' /tmp/dbcheck.out && echo "OK   instances open" || { echo "FAIL instances not open"; f=1; }
m=$(grep -o 'POC_MEM [0-9][0-9]*' /tmp/dbcheck.out | awk '{print $2}' | tail -1)
if [ -z "$m" ]; then echo "WARN could not read SGA+PGA"
elif [ "$m" -le 4500 ]; then echo "OK   memory: SGA+PGA = ${m} MB, about 30% of the 12 GiB pod"
elif [ "$m" -ge 5500 ]; then echo "FAIL memory: SGA+PGA = ${m} MB, sized from the 22 GB worker (bug 34436514); set sga_target/pga_aggregate_target for the pod"; f=1
else echo "WARN memory: SGA+PGA = ${m} MB, between the pod (3.6 GB) and worker (6.6 GB) figures; check manually"; fi
s=$(grep -o 'POC_SGA [0-9][0-9]*' /tmp/dbcheck.out | awk '{print $2}' | tail -1)
[ -n "$s" ] && { [ "$s" -le 4096 ] && echo "OK   sga_target ${s} MB fits the pod's 4 GiB of hugepages" || echo "WARN sga_target ${s} MB is more than the pod's 4 GiB of hugepages; the rest uses normal pod memory"; }
p=$(grep -o 'POC_SQLPATCH_OK [0-9][0-9]*' /tmp/dbcheck.out | awk '{print $2}' | tail -1)
[ "${p:-0}" -ge 4 ] && echo "OK   datapatch: ${p} SQL patch entries SUCCESS (RU + OJVM in root and ORCLPDB)" || { echo "FAIL datapatch: ${p:-0} SUCCESS entries, expected 4"; f=1; }
v=$(grep -o 'POC_VIOL [0-9][0-9]*' /tmp/dbcheck.out | awk '{print $2}' | tail -1)
[ "${v:-1}" -eq 0 ] && echo "OK   no unresolved PDB plug-in violations" || { echo "FAIL ${v:-?} unresolved PDB plug-in violations"; f=1; }
kubectl -n rac get pods -o wide
exit $f
'@
    Ok "Oracle RAC database ORCLCDB is open on both pods"
}
catch {
    Write-Host "`nSTOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Rerun .\14-db-install.ps1 to resume; finished steps are skipped." -ForegroundColor Yellow
    exit 1
}
