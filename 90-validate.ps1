# 90-validate.ps1
# Read-only health report for the RAC PoC cluster. Run any time, for example after starting
# the VMs:  .\90-validate.ps1      Exit code 0 = all checks passed, 1 = at least one failure.

. "$PSScriptRoot\lab-common.ps1"

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row([string]$node, [string]$status, [string]$check, [string]$detail) {
    $rows.Add([pscustomobject]@{ Node = $node; Status = $status; Check = $check; Detail = $detail })
}

Say "Validating nodes"
$asmIds = @{}
foreach ($n in $Nodes) {
    if (-not (Test-Ssh $n.Port)) { Add-Row $n.Name "FAIL" "ssh" "no answer on port $($n.Port)"; continue }
    # Push the current checker so the report never depends on an old copy on the VM
    Copy-ToVm $n.Port @((Join-Path $Here "node-validate.sh"))
    $lines = Get-Remote $n.Port "bash /root/node-validate.sh $($n.Role) $($n.Name) $($n.Ip)"
    $asmIds[$n.Name] = @()
    foreach ($l in $lines) {
        $p = $l -split '\|', 3
        if ($p.Count -lt 3) { continue }
        if ($p[0] -eq "INFO") { if ($p[1] -eq "asm-id") { $asmIds[$n.Name] += $p[2] }; continue }
        Add-Row $n.Name $p[0] $p[1] $p[2]
    }
}

# Shared disks must be the same two IDs on both workers
$a = ($asmIds["worker1"] | Sort-Object) -join ','
$b = ($asmIds["worker2"] | Sort-Object) -join ','
if ($a -and $a -eq $b) { Add-Row "workers" "PASS" "asm-shared" $a } else { Add-Row "workers" "FAIL" "asm-shared" "worker1: $a / worker2: $b" }

Say "Validating cluster"
if (Test-Ssh $CpPort) {
    $cluster = Get-Remote $CpPort @'
p() { echo "PASS|$1|$2"; }; f() { echo "FAIL|$1|$2"; }
r=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
[[ $r -eq 3 ]] && p nodes-ready "$r/3 Ready" || f nodes-ready "$r/3 Ready"
v=$(kubectl get nodes --no-headers -o custom-columns=V:.status.nodeInfo.kubeletVersion 2>/dev/null | sort -u | tr '\n' ' ')
p versions "kubelet $v"
bad=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' | wc -l)
[[ $bad -eq 0 ]] && p system-pods "all Running" || f system-pods "$bad pods not Running: $(kubectl get pods -A --no-headers | awk '$4!="Running"{print $2"("$4")"}' | tr '\n' ' ')"
for ds in kube-flannel/kube-flannel-ds kube-system/kube-multus-ds kube-system/kube-proxy; do
  n=${ds%%/*}; d=${ds##*/}
  want=$(kubectl -n $n get ds $d -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
  have=$(kubectl -n $n get ds $d -o jsonpath='{.status.numberReady}' 2>/dev/null)
  [[ -n $want && $want == "$have" && $want -eq 3 ]] && p "ds-$d" "$have/$want ready" || f "ds-$d" "${have:-0}/${want:-?} ready"
done
c=$(kubectl -n multus-rac get network-attachment-definitions --no-headers 2>/dev/null | wc -l)
[[ $c -eq 2 ]] && p nad "macvlan-conf1, macvlan-conf2" || f nad "$c of 2 found in multus-rac"
for i in 1 2; do
  m=$(kubectl -n multus-rac get net-attach-def macvlan-conf$i -o jsonpath='{.spec.config}' 2>/dev/null | tr -d ' \n')
  [[ $m == *'"master":"enp0s'* && $m == *'"ips":true'* ]] && p nad-conf$i "macvlan, ips capability" || f nad-conf$i "missing master or ips capability"
done
kubectl get cm -n kube-system kubelet-config -o yaml 2>/dev/null | grep -q 'kernel.shm' && p unsafe-sysctls "in kubelet-config" || f unsafe-sysctls "not in kubelet-config"
dns=$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c Running)
[[ $dns -ge 1 ]] && p coredns "$dns Running" || f coredns "not running"
# The PV paths must be real by-id names (not the template placeholder or an example comment)
ids=$(grep -E '^\s*path: /dev/disk/by-id/' /root/09-asm-pv.yaml 2>/dev/null | awk '{print $2}' | xargs -n1 basename 2>/dev/null | tr '\n' ' ')
if [[ ! -f /root/09-asm-pv.yaml ]]; then echo "WARN|asm-pv-file|/root/09-asm-pv.yaml missing (stage 8 of 00-build-all.ps1)"
elif [[ $(echo $ids | wc -w) -eq 2 && $ids != *REPLACE* && $ids != *__ASM* && $ids == *ata-VBOX_HARDDISK_VB* ]]; then p asm-pv-file "PV paths: $ids"
else f asm-pv-file "PV paths are not real disk IDs: ${ids:-none}"; fi
'@
    foreach ($l in $cluster) {
        $p = $l -split '\|', 3
        if ($p.Count -eq 3) { Add-Row "cluster" $p[0] $p[1] $p[2] }
    }
} else { Add-Row "cluster" "FAIL" "ssh" "controlplane not answering" }

# --------------------------------- report ---------------------------------
Say "Report"
foreach ($r in $rows) {
    $color = switch ($r.Status) { "PASS" { "Green" } "WARN" { "Yellow" } default { "Red" } }
    Write-Host ("  {0,-13} {1,-5} {2,-28} {3}" -f $r.Node, $r.Status, $r.Check, $r.Detail) -ForegroundColor $color
}
$fails = @($rows | Where-Object { $_.Status -eq "FAIL" }).Count
$warns = @($rows | Where-Object { $_.Status -eq "WARN" }).Count
$passes = @($rows | Where-Object { $_.Status -eq "PASS" }).Count
Write-Host ""
if ($fails -eq 0) { Write-Host "  RESULT: $passes passed, $warns warnings, 0 failed" -ForegroundColor Green; exit 0 }
else { Write-Host "  RESULT: $passes passed, $warns warnings, $fails FAILED" -ForegroundColor Red; exit 1 }
