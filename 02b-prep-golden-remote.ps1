# 02b-prep-golden-remote.ps1
# Runs Phase 2 from Windows over SSH: copies the scripts, runs 02-prep-golden.sh, reboots,
# verifies, takes the 'pre-seal' snapshot, then runs 03-seal-golden.sh (which powers off).
# Run after 01b-install-golden.ps1.
#
# BEFORE RUNNING: save the rac-ocne.te policy text from the Oracle doc section
# "Set up SELinux Module on Worker Nodes" as rac-ocne.te in this folder.

# Continue, not Stop: Windows PowerShell turns any ssh stderr line into a terminating error
# under Stop. Every native call below checks $LASTEXITCODE explicitly instead.
$ErrorActionPreference = "Continue"
$VBox    = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$Golden  = "ol98-golden"
$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$KeyFile = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
$SshArgs = @("-p", "2205", "-i", $KeyFile, "-o", "StrictHostKeyChecking=accept-new")
$Target  = "root@127.0.0.1"

function VB   { & $VBox @args; if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ') failed" } }
function Gssh { ssh @SshArgs $Target @args; if ($LASTEXITCODE -ne 0) { throw "ssh '$args' failed (exit $LASTEXITCODE)" } }

function Wait-Ssh {
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 10
        ssh @SshArgs -o BatchMode=yes -o ConnectTimeout=5 $Target "true" 2>&1 | Out-Null
    } until ($LASTEXITCODE -eq 0 -or (Get-Date) -gt $deadline)
    if ($LASTEXITCODE -ne 0) { throw "golden VM did not come back on SSH" }
}
function Wait-PowerOff {
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 5
        $state = (& $VBox showvminfo $Golden --machinereadable | Select-String '^VMState=').ToString()
    } until ($state -match '"poweroff"' -or (Get-Date) -gt $deadline)
    if ($state -notmatch '"poweroff"') { throw "golden VM did not power off" }
}

if (-not (Test-Path (Join-Path $Here "rac-ocne.te"))) { throw "rac-ocne.te not found in $Here (copy it from the Oracle doc)" }

# --- 1. Copy scripts and policy ---
$files = @("02-prep-golden.sh", "03-seal-golden.sh", "05-personalize-node.sh", "06-kubeadm-config.yaml",
           "07-multus-rac-nad.yaml", "08-test-multus-pods.yaml", "09-asm-pv.yaml", "rac-ocne.te") |
         ForEach-Object { Join-Path $Here $_ }
scp -P 2205 -i $KeyFile -o StrictHostKeyChecking=accept-new @files "${Target}:/root/"
if ($LASTEXITCODE -ne 0) { throw "scp failed" }
Gssh "sed -i 's/\r$//' /root/*.sh /root/*.yaml /root/rac-ocne.te"   # strip Windows line endings

# --- 2. Prep (10-20 minutes: dnf update, UEK R7, CRI-O, kubeadm) ---
Gssh "set -o pipefail; bash /root/02-prep-golden.sh 2>&1 | tee /root/02-prep-golden.log"

# --- 3. Reboot into UEK R7 and verify ---
ssh @SshArgs $Target "systemctl reboot" 2>&1 | Out-Null
Start-Sleep -Seconds 20
Wait-Ssh
Write-Host "`n--- Verification ---"
# Sent on stdin (not as an argument) so Windows PowerShell can't mangle the quotes
$verify = @'
echo "kernel:      $(uname -r)"
echo "THP:         $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "clocksource: $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
echo "swap:        $(swapon --show | wc -l) devices"
echo "selinux:     $(getenforce)"
echo "rac-ocne:    $(semodule -l | grep -c rac-ocne) module"
echo "crio:        $(systemctl is-active crio)"
echo "kubeadm:     $(kubeadm version -o short)"
'@
$verify | ssh @SshArgs $Target "tr -d '\r' | bash -s"
$kernel = ssh @SshArgs $Target "uname -r"
if ($kernel -notmatch '^5\.15\.0-.*el9uek') { throw "Not booted into UEK R7 ($kernel). Stop and check before sealing." }

# --- 4. Snapshot 'pre-seal' (lets you fix the image later), then seal ---
ssh @SshArgs $Target "systemctl poweroff" 2>&1 | Out-Null
Wait-PowerOff
# Empty every DVD drive (install ISO and VirtualBox's unattended aux ISO) so clones don't carry them
& $VBox showvminfo $Golden --machinereadable | Select-String '^"SATA-(\d+)-(\d+)"=".*\.(iso|viso)"' | ForEach-Object {
    VB storageattach $Golden --storagectl SATA --port $_.Matches[0].Groups[1].Value --device $_.Matches[0].Groups[2].Value --type dvddrive --medium emptydrive
}
VB snapshot $Golden take pre-seal --description "Prepared golden image before sealing"
# The VM's session lock can linger a few seconds after power-off/snapshot, so retry the start
for ($i = 1; $i -le 6; $i++) {
    Start-Sleep -Seconds 10
    & $VBox startvm $Golden --type headless 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    Write-Host "VM still locked, retrying ($i/6)..."
}
if ($LASTEXITCODE -ne 0) { throw "Could not start $Golden (session still locked). Close any VirtualBox window for it and rerun from the seal step." }
Wait-Ssh
ssh @SshArgs $Target "bash /root/03-seal-golden.sh" 2>&1 | Out-Null
Wait-PowerOff

# Seal removed the host keys; forget the old one so a later boot from 'pre-seal' doesn't warn
ssh-keygen -R "[127.0.0.1]:2205" 2>&1 | Out-Null

Write-Host "`nGolden image prepared, snapshotted (pre-seal) and sealed. Next: .\04-clone-nodes.ps1"
