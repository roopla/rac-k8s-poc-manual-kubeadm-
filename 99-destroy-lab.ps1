# 99-destroy-lab.ps1
# Permanently deletes the whole lab: the three nodes, the golden VM (with its pre-seal
# snapshot), every disk including the shared ASM disks, and the k8s-public NAT Network.
# Use it to start over with .\00-build-all.ps1. Asks for confirmation first.
#
#   .\99-destroy-lab.ps1               # everything
#   .\99-destroy-lab.ps1 -KeepGolden   # keep the sealed golden VM, rebuild only the cluster

param([switch]$KeepGolden)
. "$PSScriptRoot\lab-common.ps1"

$targets = @("worker2", "worker1", "controlplane")
if (-not $KeepGolden) { $targets += $Lab.Golden }
$present = $targets | Where-Object { Test-Vm $_ }

Write-Host "This permanently deletes: $($present -join ', '), the shared ASM disks" -ForegroundColor Yellow
if (-not $KeepGolden) { Write-Host "and the NAT Network $($Lab.NatNet)." -ForegroundColor Yellow }
$answer = Read-Host "Type DESTROY to continue"
if ($answer -cne "DESTROY") { Write-Host "Cancelled. Nothing was changed."; exit 0 }

foreach ($vm in $present) {
    if ((Get-VmState $vm) -eq "running") {
        & $Lab.VBox controlvm $vm poweroff 2>&1 | Out-Null
        Wait-VmState $vm "poweroff" 60
    }
}
Start-Sleep -Seconds 3

# Detach the shared disks first so they are not kept alive by the other worker
foreach ($w in "worker1", "worker2") {
    if (Test-Vm $w) {
        foreach ($port in 3, 4) { & $Lab.VBox storageattach $w --storagectl SATA --port $port --device 0 --medium none 2>&1 | Out-Null }
    }
}
foreach ($vm in $present) {
    VB unregistervm $vm --delete
    Ok "Deleted $vm and its disks"
}
foreach ($d in "asm1", "asm2") {
    $f = Join-Path (Join-Path $Lab.BaseDir "shared") "$d.vdi"
    if (Test-Path $f) {
        & $Lab.VBox closemedium disk $f --delete 2>&1 | Out-Null
        if (Test-Path $f) { Remove-Item $f -Force }
        Ok "Deleted $d.vdi"
    }
}
if (-not $KeepGolden) {
    & $Lab.VBox natnetwork remove --netname $Lab.NatNet 2>&1 | Out-Null
    Ok "Removed NAT Network $($Lab.NatNet)"
}
# Leftover empty folders and unattended-install files
foreach ($vm in $targets) {
    $dir = Join-Path $Lab.BaseDir $vm
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
Remove-Item (Join-Path $Here "09-asm-pv.yaml") -ErrorAction SilentlyContinue
Write-Host "`nLab removed. Rebuild with .\00-build-all.ps1" -ForegroundColor Green
