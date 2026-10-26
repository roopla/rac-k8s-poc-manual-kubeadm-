# 12-rac-pods.ps1
# Oracle doc, "Create the Oracle RAC Pods": SSH key secret, headless services, both RAC
# StatefulSets, then checks that each pod is ready for the Grid install. Safe to rerun:
# existing objects are kept (kubectl apply), the SSH secret is only created once.
#
#   .\12-rac-pods.ps1               # create/update and check
#   .\12-rac-pods.ps1 -CheckOnly    # only run the checks
#   .\12-rac-pods.ps1 -Delete       # remove the pods and services (keeps /u01 data, ASM disks, secret)

param([switch]$CheckOnly, [switch]$Delete)
. "$PSScriptRoot\lab-common.ps1"

$files = @("rac\racnode-svc.yaml", "rac\rac1_sts.yaml", "rac\rac2_sts.yaml") | ForEach-Object { Join-Path $Here $_ }

try {
    if (-not (Test-Ssh $CpPort)) { throw "controlplane not answering on port $CpPort" }

    if ($Delete) {
        Say "Deleting the RAC StatefulSets and services"
        Invoke-Remote $CpPort 'kubectl -n rac delete statefulset racnode1 racnode2 --ignore-not-found --wait; kubectl -n rac delete -f /root/rac/racnode-svc.yaml --ignore-not-found; kubectl -n rac get all'
        Ok "Removed. /u01 contents on the workers, the ASM disks and ssh-key-secret are untouched."
        exit 0
    }

    if (-not $CheckOnly) {
        # ------------------------------------------------------------ 1. prerequisites
        Say "1. Prerequisites"
        Invoke-Remote $CpPort @'
f=0
kubectl get ns rac >/dev/null 2>&1 && echo "OK   namespace rac" || { echo "FAIL namespace rac missing (run 10-rac-image-and-asm.ps1)"; f=1; }
b=$(kubectl -n rac get pvc --no-headers 2>/dev/null | grep -c Bound); [ "$b" -eq 2 ] && echo "OK   2 ASM PVCs Bound" || { echo "FAIL $b of 2 ASM PVCs Bound"; f=1; }
c=$(kubectl -n multus-rac get net-attach-def --no-headers 2>/dev/null | wc -l); [ "$c" -eq 2 ] && echo "OK   Multus networks" || { echo "FAIL Multus networks ($c)"; f=1; }
kubectl -n rac get pod rac-smoke >/dev/null 2>&1 && { echo "FAIL smoke-test pod still exists (it holds .147 and the ASM devices)"; f=1; } || echo "OK   no smoke-test pod"
exit $f
'@
        foreach ($w in $Workers) {
            Invoke-Remote $w.Port "f=0; crictl images | grep -q 'oracle/database-rac.*19-ol9-slim' && echo 'OK   $($w.Name): RAC image present' || { echo 'FAIL $($w.Name): RAC image missing'; f=1; }; exit `$f"
        }
        Invoke-Remote 2211 'ls -lh /scratch/software/stage/oracle-*-19.32.zip | awk "{print \"OK   worker1 stage: \" \$NF \" \" \$5}"; [ $(ls /scratch/software/stage/oracle-*-19.32.zip | wc -l) -eq 2 ]'
        Ok "Prerequisites met"

        # ------------------------------------------------------------ 2. secret, services, StatefulSets
        Say "2. SSH key secret, headless services, StatefulSets"
        Invoke-Remote $CpPort 'mkdir -p /root/rac' -Quiet
        Copy-ToVm $CpPort $files "/root/rac/"
        Invoke-Remote $CpPort @'
set -e
if kubectl -n rac get secret ssh-key-secret >/dev/null 2>&1; then
  echo "ssh-key-secret already exists (kept)"
else
  rm -f /root/rac/id_rsa /root/rac/id_rsa.pub
  ssh-keygen -q -t rsa -b 3072 -N "" -C "Key_Pair_for_ssh_connectivity_for_rac_setup" -f /root/rac/id_rsa
  kubectl -n rac create secret generic ssh-key-secret --from-file=/root/rac/id_rsa --from-file=/root/rac/id_rsa.pub
fi
kubectl apply -f /root/rac/racnode-svc.yaml
kubectl apply -f /root/rac/rac1_sts.yaml
kubectl apply -f /root/rac/rac2_sts.yaml
'@
        Ok "Objects applied"
    }

    # ---------------------------------------------------------------- 3. wait for the pods
    Say "3. Waiting for racnode1-0 and racnode2-0 to run (not Ready: port 1521 opens only after Grid)"
    Invoke-Remote $CpPort @'
for i in $(seq 1 60); do
  r=$(kubectl -n rac get pod racnode1-0 racnode2-0 -o jsonpath='{range .items[*]}{.status.phase}{" "}{end}' 2>/dev/null)
  [ "$r" = "Running Running " ] && break; sleep 5
done
kubectl -n rac get pods -o wide
[ "$r" = "Running Running " ] || { echo "Pods not Running after 5 minutes:"; kubectl -n rac describe pods | sed -n '/^Events:/,$p' | tail -20; exit 1; }
'@
    Ok "Both pods Running"

    # ---------------------------------------------------------------- 4. per-pod checks
    Say "4. Checks inside each pod"
    Invoke-Remote $CpPort @'
F=0
X() { kubectl -n rac exec "$1" -- bash -c "$2" 2>/dev/null; }
for n in 1 2; do
  p=racnode$n-0; o=$((140 + n)); peer=$((143 - n)); f=0
  echo "--- $p ($(kubectl -n rac get pod $p -o jsonpath='{.spec.nodeName}'))"
  for i in $(seq 1 40); do st=$(X $p 'systemctl is-system-running; true'); [[ $st == starting || $st == initializing ]] || break; sleep 3; done
  [[ $st == running || $st == degraded ]] && echo "OK   systemd $st" || { echo "FAIL systemd $st"; f=1; }
  h=$(X $p hostname); [ "$h" = "$p" ] && echo "OK   hostname $h" || { echo "FAIL hostname '$h'"; f=1; }
  a1=$(X $p "ip -4 -o addr show eth1 | awk '{print \$4}' | head -1"); a2=$(X $p "ip -4 -o addr show eth2 | awk '{print \$4}' | head -1")
  [[ $a1 == 10.0.11.$o/24 && $a2 == 10.0.12.$o/24 ]] && echo "OK   eth1 $a1  eth2 $a2" || { echo "FAIL eth1 '$a1' eth2 '$a2'"; f=1; }
  for net in 11 12; do X $p "ping -c2 -W2 10.0.$net.$peer >/dev/null" && echo "OK   ping 10.0.$net.$peer (other node)" || { echo "FAIL ping 10.0.$net.$peer"; f=1; }; done
  for d in 1 2; do s=$(X $p "stat -c '%U:%G %a' /dev/asm-disk$d"); [ "$s" = "grid:asmadmin 660" ] && echo "OK   /dev/asm-disk$d $s" || { echo "FAIL /dev/asm-disk$d '$s'"; f=1; }; done
  X $p 'touch /u01/.w && rm -f /u01/.w' && echo "OK   /u01 writable ($(X $p "df -h /u01 | awk 'NR==2{print \$4}'") free)" || { echo "FAIL /u01 not writable"; f=1; }
  X $p 'test -f /mnt/.ssh/id_rsa && test -f /mnt/.ssh/id_rsa.pub && ! touch /mnt/.ssh/x 2>/dev/null' && echo "OK   /mnt/.ssh keys present, read-only" || { echo "FAIL /mnt/.ssh"; f=1; }
  if [ $n -eq 1 ]; then
    c=$(X $p 'ls /stage/oracle-*-19.32.zip 2>/dev/null | wc -l'); [ "$c" = 2 ] && echo "OK   /stage has both 19.32 zips" || { echo "FAIL /stage has $c zips"; f=1; }
  fi
  for name in racnode1-0 racnode2-0 racnode1-0-vip racnode2-0-vip racnode-scan; do
    ips=$(X $p "getent ahostsv4 $name | awk '{print \$1}' | sort -u | tr '\n' ' '")
    [ -n "$ips" ] && echo "OK   DNS $name -> $ips" || { echo "FAIL DNS $name"; f=1; }
  done
  m=$(X $p 'cat /sys/fs/cgroup/memory.max'); [[ $m =~ ^[0-9]+$ ]] && echo "INFO memory limit seen in pod: $((m / 1024 / 1024 / 1024)) GiB" || echo "INFO memory limit seen in pod: ${m:-unknown}"
  hp=$(X $p 'cat /sys/fs/cgroup/hugetlb.2MB.max 2>/dev/null'); [[ $hp =~ ^[0-9]+$ ]] && echo "INFO hugepages limit: $((hp / 1024 / 1024 / 1024)) GiB"
  for k in kernel.sem kernel.shmmax; do echo "INFO $k = $(X $p "sysctl -n $k" | tr '\t' ' ')"; done
  [ $f -eq 0 ] || F=1
done
exit $F
'@
    Ok "Both RAC pods are ready for the Grid install"
    Say "Next"
    Info "Grid Infrastructure in the pods: the doc's 'Deploy Oracle Grid Infrastructure in the Kubernetes Pods'"
    Info "with the gold-image changes from the build guide (unzip /stage/oracle-gridhome-19.32.zip, no -applyRU)."
}
catch {
    Write-Host "`nSTOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Fix the cause and rerun .\12-rac-pods.ps1" -ForegroundColor Yellow
    exit 1
}
