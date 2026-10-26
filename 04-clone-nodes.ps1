# 04-clone-nodes.ps1
# Clones the sealed golden VM into controlplane, worker1, worker2, resizes them,
# adds the worker data disks and the two shared ASM disks.
# Run in PowerShell on the Windows host after 03-seal-golden.sh has powered the golden VM off.

$ErrorActionPreference = "Stop"
$VBox   = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$Base   = "D:\VMs\rac-poc"          # same as in 01-create-golden-vm.ps1
$Golden = "ol98-golden"

# Sizes (see "Host sizing" in the guide)
$WorkerCpus = 4                     # host has 8 cores / 8 threads; RAC pod CPU becomes 3
$WorkerMemMB = 22528                # 22 GB
$CpCpus = 2
$CpMemMB = 4096

function VB { & $VBox @args; if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ') failed" } }

# Detach the install ISO so clones don't boot from it
VB storageattach $Golden --storagectl SATA --port 5 --device 0 --type dvddrive --medium emptydrive

# --- 1. Full clones (new hardware UUID and MAC addresses per clone) ---
foreach ($n in "controlplane", "worker1", "worker2") {
    VB clonevm $Golden --name $n --basefolder $Base --mode machine --register
}

# --- 2. Control plane: smaller, no RAC private NICs ---
VB modifyvm controlplane --cpus $CpCpus --memory $CpMemMB --nic2 none --nic3 none

# --- 3. Workers: CPU/RAM + /scratch (80 GB, port 1) + /var/lib/containers (100 GB, port 2) ---
foreach ($n in "worker1", "worker2") {
    VB modifyvm $n --cpus $WorkerCpus --memory $WorkerMemMB
    $dir = Join-Path $Base $n
    $scratch = Join-Path $dir "$n-scratch.vdi"
    $cont    = Join-Path $dir "$n-containers.vdi"
    VB createmedium disk --filename $scratch --size 81920  --variant Standard
    VB createmedium disk --filename $cont    --size 102400 --variant Standard
    VB storageattach $n --storagectl SATA --port 1 --device 0 --type hdd --medium $scratch
    VB storageattach $n --storagectl SATA --port 2 --device 0 --type hdd --medium $cont
}

# --- 4. Shared ASM disks: fixed size (required for shareable), attached to both workers ---
$SharedDir = Join-Path $Base "shared"
New-Item -ItemType Directory -Force -Path $SharedDir | Out-Null
$port = 3
foreach ($d in "asm1", "asm2") {
    $f = Join-Path $SharedDir "$d.vdi"
    VB createmedium disk --filename $f --size 51200 --variant Fixed     # 50 GB, takes a few minutes
    VB modifymedium disk $f --type shareable
    foreach ($n in "worker1", "worker2") {
        VB storageattach $n --storagectl SATA --port $port --device 0 --type hdd --medium $f --mtype shareable
    }
    $port++
}

# Check BOTH shared disks: shareable, and attached to both workers
foreach ($d in "asm1", "asm2") {
    $f = Join-Path $SharedDir "$d.vdi"
    $info = (& $VBox showmediuminfo disk $f) -join "`n"
    $uuid = if ($info -match 'UUID:\s+([0-9a-f]{8})') { $Matches[1] } else { "?" }
    if ($info -notmatch 'Type:\s+shareable' -or $info -notmatch 'worker1 \(UUID' -or $info -notmatch 'worker2 \(UUID') {
        throw "$d.vdi is not shareable or not attached to both workers:`n$info"
    }
    Write-Host "OK  $d.vdi shareable, on worker1 and worker2, by-id ata-VBOX_HARDDISK_VB$uuid-..."
}

Write-Host "`nClones ready. Start and personalize ONE AT A TIME (they all boot with 10.0.1.5):"
Write-Host "  & '$VBox' startvm controlplane --type gui"
