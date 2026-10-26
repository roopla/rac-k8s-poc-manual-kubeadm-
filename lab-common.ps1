# lab-common.ps1
# Shared settings and helpers for the Oracle RAC on kubeadm PoC lab.
# Dot-sourced by 00-build-all.ps1, 90-validate.ps1 and 99-destroy-lab.ps1. Not run directly.
# Written for Windows PowerShell 5.1 and VirtualBox 7.x.

# Windows PowerShell turns ssh/VBoxManage stderr into terminating errors under "Stop",
# so every native call below checks $LASTEXITCODE explicitly instead.
$ErrorActionPreference = "Continue"

# ============================== SETTINGS: edit these ==============================
$Lab = @{
    VBox        = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
    BaseDir     = "D:\VMs\rac-poc"                                         # VM folders and disks
    Iso         = "D:\ISO images\OracleLinux-R9-U8-x86_64-dvd-20260618.iso" # Oracle Linux 9.8 DVD
    KeyFile     = (Join-Path $env:USERPROFILE ".ssh\id_ed25519")           # created with ssh-keygen
    Golden      = "ol98-golden"
    NatNet      = "k8s-public"
    K8sMinor    = "v1.36"
    CrioMinor   = "v1.36"
    FlannelUrl  = "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
    MultusUrl   = "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml"
    CpCpus      = 2
    CpMemMB     = 4096
    WorkerMemMB = 22528        # 22 GB
    WorkerCpus  = 0            # 0 = choose from host threads: >=16 -> 6, >=12 -> 5, else 4
}
# ===================================================================================

$Nodes = @(
    @{ Name = "controlplane"; Ip = "10.0.1.10"; Port = 2210; Role = "cp" },
    @{ Name = "worker1";      Ip = "10.0.1.11"; Port = 2211; Role = "worker" },
    @{ Name = "worker2";      Ip = "10.0.1.12"; Port = 2212; Role = "worker" }
)
$Workers    = $Nodes | Where-Object { $_.Role -eq "worker" }
$GoldenPort = 2205
$Here       = $PSScriptRoot
$CpPort     = 2210

# Lab-only SSH: every VM is reached through 127.0.0.1 port forwards and host keys change on
# every rebuild, so known_hosts is not used. Do not copy these options to real systems.
$SshBase = @("-i", $Lab.KeyFile, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL",
             "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6")

# ------------------------------------ output ------------------------------------
function Say([string]$msg)  { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Info([string]$msg) { Write-Host "  $msg" }
function Ok([string]$msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn([string]$msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }

# ---------------------------------- VirtualBox ----------------------------------
function VB {
    $out = & $Lab.VBox @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "VBoxManage $($args -join ' ') failed"
    }
}
function Test-Vm([string]$name) {
    $list = & $Lab.VBox list vms 2>$null
    return [bool]($list | Where-Object { $_ -like "`"$name`" *" })
}
function Get-VmInfo([string]$name) { return (& $Lab.VBox showvminfo $name --machinereadable 2>$null) }
function Get-VmState([string]$name) {
    $line = Get-VmInfo $name | Where-Object { $_ -like 'VMState=*' } | Select-Object -First 1
    if ($line) { return ($line -replace '^VMState="(.*)"$', '$1') } else { return "" }
}
function Wait-VmState([string]$name, [string]$state, [int]$timeoutSec = 300) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VmState $name) -eq $state) { return }
        Start-Sleep -Seconds 5
    }
    throw "$name did not reach state '$state' within $timeoutSec s"
}
function Start-Vm([string]$name) {
    if ((Get-VmState $name) -eq "running") { return }
    # The session lock can linger for a few seconds after a power-off or snapshot
    for ($i = 1; $i -le 6; $i++) {
        & $Lab.VBox startvm $name --type headless 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 10
    }
    throw "Could not start $name (session still locked?). Close any VirtualBox window for it and rerun."
}
function Stop-VmAcpi([string]$name, [int]$timeoutSec = 180) {
    if ((Get-VmState $name) -ne "running") { return }
    & $Lab.VBox controlvm $name acpipowerbutton 2>&1 | Out-Null
    Wait-VmState $name "poweroff" $timeoutSec
}
function Get-Extra([string]$vm, [string]$key) {
    $v = "$(& $Lab.VBox getextradata $vm $key 2>$null)"
    if ($v -match 'Value: (\S+)') { return $Matches[1] } else { return "" }
}
function Set-Extra([string]$vm, [string]$key, [string]$val) { VB setextradata $vm $key $val }
function Test-Snapshot([string]$vm, [string]$snap) {
    $list = & $Lab.VBox snapshot $vm list --machinereadable 2>$null
    return [bool]($list | Where-Object { $_ -like "*=`"$snap`"" })
}
function Clear-DvdDrives([string]$vm) {
    # Empty every DVD drive (install ISO and the unattended-install aux ISO) on the SATA controller
    Get-VmInfo $vm | ForEach-Object {
        if ($_ -match '^"SATA-(\d+)-(\d+)"=".*\.(iso|viso)"$') {
            VB storageattach $vm --storagectl SATA --port $Matches[1] --device $Matches[2] --type dvddrive --medium emptydrive
        }
    }
}

# -------------------------------------- SSH --------------------------------------
function Test-Ssh([int]$port) {
    ssh -p $port @SshBase -o BatchMode=yes root@127.0.0.1 "true" 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}
function Wait-Ssh([int]$port, [int]$minutes = 10) {
    $deadline = (Get-Date).AddMinutes($minutes)
    while ((Get-Date) -lt $deadline) {
        if (Test-Ssh $port) { Write-Host ""; return $true }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 10
    }
    Write-Host ""
    return $false
}
# Run a bash script on a VM. The script goes over stdin, so Windows PowerShell cannot mangle
# its quotes. Output is printed (indented) unless -Quiet. Throws on a non-zero exit unless -AllowFail.
function Invoke-Remote([int]$port, [string]$script, [switch]$AllowFail, [switch]$Quiet) {
    $out = $script | ssh -p $port @SshBase -o BatchMode=yes root@127.0.0.1 "tr -d '\r' | bash -s" 2>&1
    $code = $LASTEXITCODE
    if (-not $Quiet) { $out | ForEach-Object { Write-Host "    $_" } }
    if ($code -ne 0 -and -not $AllowFail) {
        if ($Quiet) { $out | ForEach-Object { Write-Host "    $_" -ForegroundColor Red } }
        throw "Remote script on port $port failed (exit $code)"
    }
}
# Same, but returns the output lines instead of printing them
function Get-Remote([int]$port, [string]$script) {
    $out = $script | ssh -p $port @SshBase -o BatchMode=yes root@127.0.0.1 "tr -d '\r' | bash -s" 2>$null
    return @($out | ForEach-Object { "$_" })
}
# Run a long command and stream its output live (no capture)
function Invoke-RemoteStream([int]$port, [string]$command) {
    ssh -p $port @SshBase -o BatchMode=yes root@127.0.0.1 $command
    if ($LASTEXITCODE -ne 0) { throw "Remote command on port $port failed (exit $LASTEXITCODE)" }
}
function Copy-ToVm([int]$port, [string[]]$files, [string]$dest = "/root/") {
    foreach ($f in $files) { if (-not (Test-Path $f)) { throw "Missing file: $f" } }
    scp -P $port @SshBase -o BatchMode=yes @files "root@127.0.0.1:$dest" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "scp to port $port failed" }
    # Strip Windows line endings from everything just copied
    $names = ($files | ForEach-Object { $dest + (Split-Path $_ -Leaf) }) -join ' '
    Invoke-Remote $port ('sed -i ''s/\r$//'' ' + $names) -Quiet
}
