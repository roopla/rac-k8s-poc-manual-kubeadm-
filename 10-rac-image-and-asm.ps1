# 10-rac-image-and-asm.ps1
# Phase 6 (no Oracle software needed): builds the RAC pod image on worker1 from Oracle Linux 9
# exactly as the Oracle doc does (rac-image\Containerfile),
# copies it to worker2, creates the rac namespace and ASM volumes, then runs a smoke-test pod with
# the doc's RAC pod settings and checks it. Safe to rerun.
#
#   .\10-rac-image-and-asm.ps1            # build (if needed), volumes, smoke test
#   .\10-rac-image-and-asm.ps1 -Rebuild   # rebuild the image even if it exists
#   .\10-rac-image-and-asm.ps1 -Rebuild -ImageOnly   # rebuild + copy + check only; no volumes, no
#                                                    # smoke pod (use this while the RAC pods run)

param([switch]$Rebuild, [switch]$ImageOnly)
. "$PSScriptRoot\lab-common.ps1"

$Image = "localhost/oracle/database-rac:19-ol9-slim"
$W1 = 2211; $W2 = 2212

try {
    foreach ($p in $CpPort, $W1, $W2) { if (-not (Test-Ssh $p)) { throw "Node on port $p not answering. Start the VMs first." } }

    # ---------------------------------------------------------------- 1. build on worker1
    Say "1. Build $Image on worker1"
    $have = (Get-Remote $W1 "podman image exists $Image && echo yes") -contains "yes"
    if ($have -and -not $Rebuild) { Ok "Image already on worker1 (use -Rebuild to rebuild)" }
    else {
        Copy-ToVm $W1 @((Join-Path $Here "rac-image\Containerfile"), (Join-Path $Here "rac-image\setupContainerEnv.sh")) "/scratch/image/"
        Info "Building from container-registry.oracle.com/os/oraclelinux:9 (3-6 minutes: dnf install)"
        Invoke-RemoteStream $W1 "cd /scratch/image && chmod +x setupContainerEnv.sh && podman build --pull=missing --force-rm=true -t $Image -f Containerfile . 2>&1 | grep -E '^(STEP|COMMIT|Successfully|Error)|error'; podman image exists $Image"
        Ok "Built $Image"
    }

    # ---------------------------------------------------------------- 2. copy to worker2
    Say "2. Copy the image to worker2"
    $id1 = "$(Get-Remote $W1 "podman image inspect $Image --format '{{.Id}}'")".Trim()
    $id2 = "$(Get-Remote $W2 "podman image inspect $Image --format '{{.Id}}' 2>/dev/null")".Trim()
    if ($id1 -and $id1 -eq $id2) { Ok "worker2 already has the same image ($($id1.Substring(0,12)))" }
    else {
        # Copy worker1 -> worker2 over 10.0.1.x, as the doc does. Going through this PC is far too
        # slow: VirtualBox NAT port forwarding managed about 0.1 MB/s for the 400 MB image.
        Info "Authorizing worker1's SSH key on worker2"
        $pub = Get-Remote $W1 "test -f ~/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519; cat ~/.ssh/id_ed25519.pub"
        $pub = ($pub | Where-Object { $_ -like 'ssh-ed25519 *' } | Select-Object -First 1)
        if (-not $pub) { throw "Could not read worker1's SSH public key" }
        Invoke-Remote $W2 ("mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qF '$pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys") -Quiet
        Info "Saving on worker1 and copying straight to worker2 (about 400 MB)"
        Invoke-Remote $W1 @"
set -e
rm -f /var/tmp/database-rac.tar
podman image save -o /var/tmp/database-rac.tar $Image
scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes /var/tmp/database-rac.tar root@10.0.1.12:/var/tmp/
ssh -o BatchMode=yes root@10.0.1.12 'podman image load -q -i /var/tmp/database-rac.tar && rm -f /var/tmp/database-rac.tar'
rm -f /var/tmp/database-rac.tar
"@
        $id2 = "$(Get-Remote $W2 "podman image inspect $Image --format '{{.Id}}'")".Trim()
        if ($id1 -ne $id2) { throw "Image IDs differ after load (worker1 $id1, worker2 $id2)" }
        Ok "worker2 has the same image ($($id1.Substring(0,12)))"
    }
    Invoke-Remote $W1 "crictl images | grep -E 'IMAGE|database-rac'"

    # ---------------------------------------------------------------- 3. image content checks
    Say "3. Check the image"
    Invoke-Remote $W1 @"
podman run --rm --entrypoint /bin/bash $Image -c '
f=0
grep -q runOracle /etc/rc.d/rc.local && { echo "FAIL rc.local still starts runOracle.sh"; f=1; } || echo "OK   rc.local does not start Oracle automation"
grep -q setupContainerEnv /etc/rc.d/rc.local && echo "OK   rc.local runs setupContainerEnv.sh" || { echo "FAIL setupContainerEnv.sh not in rc.local"; f=1; }
grep -q restart-state/onstart.sh /opt/scripts/startup/setupContainerEnv.sh && echo "OK   setupContainerEnv.sh calls the /u01 restart hook" || { echo "FAIL no restart hook in setupContainerEnv.sh"; f=1; }
[ -x /etc/rc.d/rc.local ] && echo "OK   rc.local executable" || { echo "FAIL rc.local not executable"; f=1; }
[ "`$(id -u grid)" = 54332 ] && id -nG grid | grep -qw asmadmin && echo "OK   grid 54332 in asmadmin" || { echo "FAIL grid user/groups"; f=1; }
[ -f /etc/security/limits.d/grid-database-preinstall-19c.conf ] && echo "OK   grid limits file" || { echo "FAIL grid limits file"; f=1; }
ls /usr/lib/systemd/system/dnf-makecache.* >/dev/null 2>&1 && { echo "FAIL dnf-makecache still present"; f=1; } || echo "OK   dnf-makecache removed"
grep -q "Oracle Linux Server release 9" /etc/oracle-release && echo "OK   `$(cat /etc/oracle-release)" || { echo "FAIL not Oracle Linux 9"; f=1; }
rpm -q oracle-database-preinstall-19c >/dev/null && echo "OK   oracle-database-preinstall-19c installed" || { echo "FAIL preinstall rpm missing"; f=1; }
id -nG oracle | grep -qw asmdba && echo "OK   oracle in asmdba" || { echo "FAIL oracle not in asmdba"; f=1; }
getcap /usr/bin/ping | grep -q cap_net_raw && echo "OK   ping capabilities" || { echo "FAIL ping capabilities"; f=1; }
exit `$f'
"@
    Ok "Image content as the doc expects"
    if ($ImageOnly) {
        Info "Running RAC pods keep the image they started with; a recreated pod uses the new one."
        exit 0
    }

    # ---------------------------------------------------------------- 4. rac namespace + ASM volumes
    Say "4. rac namespace and ASM volumes"
    $pv = Join-Path $Here "09-asm-pv.yaml"
    if (-not (Test-Path $pv)) { throw "09-asm-pv.yaml not found. Run stage 8 of 00-build-all.ps1 to generate it." }
    if ((Get-Content $pv -Raw) -match 'REPLACE|__ASM') { throw "09-asm-pv.yaml still has placeholders instead of disk IDs" }
    Copy-ToVm $CpPort @($pv)
    Invoke-Remote $CpPort @'
kubectl create namespace rac --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f /root/09-asm-pv.yaml >/dev/null
for i in $(seq 1 30); do
  b=$(kubectl -n rac get pvc --no-headers 2>/dev/null | grep -c Bound); [ "$b" -eq 2 ] && break; sleep 2
done
kubectl get pv; echo; kubectl -n rac get pvc
[ "$(kubectl -n rac get pvc --no-headers | grep -c Bound)" -eq 2 ]
'@
    Ok "Both ASM PVCs Bound in namespace rac"

    # ---------------------------------------------------------------- 5. smoke-test pod
    $racUp = (Get-Remote $CpPort "kubectl -n rac get pod racnode1-0 racnode2-0 --no-headers 2>/dev/null | wc -l") -contains "2"
    if ($racUp) {
        Ok "RAC pods are running: smoke test skipped (it would compete for the ASM devices and hugepages)"
        exit 0
    }
    Say "5. Smoke test: one pod with the doc's RAC pod settings on worker1"
    Copy-ToVm $CpPort @((Join-Path $Here "11-rac-smoke-pod.yaml"))
    Invoke-Remote $CpPort @'
kubectl get node worker1 -o jsonpath='worker1 allocatable hugepages-2Mi: {.status.allocatable.hugepages-2Mi}{"\n"}'
kubectl -n rac delete pod rac-smoke --ignore-not-found --wait >/dev/null
kubectl apply -f /root/11-rac-smoke-pod.yaml >/dev/null
if ! kubectl -n rac wait --for=condition=Ready pod/rac-smoke --timeout=300s >/dev/null; then
  kubectl -n rac describe pod rac-smoke | tail -20; exit 1
fi
X() { kubectl -n rac exec rac-smoke -- bash -c "$1" 2>&1; }
for i in $(seq 1 60); do   # let systemd finish booting and rc.local run (up to 3 minutes)
  st=$(X 'systemctl is-system-running 2>/dev/null; true'); [[ $st == starting || $st == initializing ]] || break; sleep 3
done
f=0
pid1=$(X 'cat /proc/1/comm'); [ "$pid1" = systemd ] && echo "OK   PID 1 is systemd" || { echo "FAIL PID 1 is '$pid1'"; f=1; }
[[ $st == running || $st == degraded ]] && echo "OK   systemd state: $st" || { echo "FAIL systemd state: $st"; f=1; }
X 'systemctl --failed --no-legend 2>/dev/null; true' | sed 's/^/     failed unit: /'
X 'pgrep -f "[m]ain\.py" >/dev/null' && { echo "FAIL Oracle automation (main.py) is running"; f=1; } || echo "OK   no Oracle automation running"
for d in 1 2; do
  o=$(X "stat -c '%U:%G %a %F' /dev/asm-disk$d")
  [[ $o == "grid:asmadmin 660 block special file" ]] && echo "OK   /dev/asm-disk$d $o" || { echo "FAIL /dev/asm-disk$d $o"; f=1; }
done
X 'su - grid -c "dd if=/dev/asm-disk1 of=/dev/null bs=1M count=1 status=none"' && echo "OK   grid can read /dev/asm-disk1" || { echo "FAIL grid cannot read /dev/asm-disk1"; f=1; }
s=$(X 'sysctl -n kernel.sem'); [[ $s == "250	32000	100	128" || $s == "250 32000 100 128" ]] && echo "OK   kernel.sem $s" || { echo "FAIL kernel.sem $s"; f=1; }
s=$(X 'sysctl -n kernel.shmmax'); [ "$s" = 8589934592 ] && echo "OK   kernel.shmmax $s" || { echo "FAIL kernel.shmmax $s"; f=1; }
s=$(X 'df -h /dev/shm | tail -1 | awk "{print \$1}"'); [ "$s" = tmpfs ] && echo "OK   /dev/shm is tmpfs" || { echo "FAIL /dev/shm is $s"; f=1; }
a1=$(X 'ip -4 -o addr show eth1 | awk "{print \$4}"'); a2=$(X 'ip -4 -o addr show eth2 | awk "{print \$4}"')
[[ $a1 == 10.0.11.147/24 && $a2 == 10.0.12.147/24 ]] && echo "OK   eth1 $a1, eth2 $a2" || { echo "FAIL eth1 '$a1' eth2 '$a2'"; f=1; }
X 'getcap /usr/bin/ping | grep -q cap_net_raw' && echo "OK   ping capabilities" || { echo "FAIL ping capabilities"; f=1; }
kubectl -n rac delete pod rac-smoke --wait >/dev/null
echo "smoke pod deleted"
exit $f
'@
    Ok "RAC pod settings work on this cluster (systemd, SELinux policy, sysctls, hugepages, ASM devices, Multus)"

    Say "Phase 6 (image and ASM) done"
    Info "Image on both workers: $Image   (use this in the RAC StatefulSets, imagePullPolicy: IfNotPresent)"
    Info "Next: stage the Oracle zips on worker1:/scratch/software/stage, then the doc's 'Create the Oracle RAC Pods'"
}
catch {
    Write-Host "`nSTOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Fix the cause and rerun .\10-rac-image-and-asm.ps1 (finished steps are skipped)." -ForegroundColor Yellow
    exit 1
}
