# 01b-install-golden.ps1
# Installs Oracle Linux 9.8 on the golden VM with no clicks, using VirtualBox unattended
# install and a kickstart file generated here. Run after 01-create-golden-vm.ps1.
#
# What the kickstart sets (same choices as the guide's Phase 1):
#   Minimal install, LVM / on the whole 50 GB disk, NO swap, SELinux enforcing,
#   enp0s3 static 10.0.1.5/24 gw 10.0.1.1 dns 8.8.8.8, hostname ol98-golden,
#   root password you type below, and your Windows SSH public key in root's authorized_keys
#   so the next scripts run without password prompts.

$ErrorActionPreference = "Stop"
$VBox   = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$Iso    = "D:\ISO\OracleLinux-R9-U8-x86_64-dvd.iso"   # same as in 01-create-golden-vm.ps1
$Golden = "ol98-golden"
$Here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Ks     = Join-Path $Here "ol98-golden-ks.cfg"

function VB { & $VBox @args; if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ') failed" } }

# --- 1. SSH key on Windows (created if missing) ---
$KeyFile = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
if (-not (Test-Path "$KeyFile.pub")) {
    throw "No SSH key at $KeyFile. Run:  ssh-keygen -t ed25519   (press Enter for the default path and an empty passphrase), then rerun this script."
}
$PubKey = (Get-Content "$KeyFile.pub" -Raw).Trim()

# --- 2. Root password (lab only; avoid " and spaces) ---
$Sec = Read-Host "Root password for the VMs" -AsSecureString
$Pw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Sec))
if ($Pw -match '[" ]' -or $Pw.Length -lt 8) { throw "Use 8+ characters with no spaces or double quotes." }

# --- 3. Kickstart ---
$ksText = @"
# Kickstart for ol98-golden (Oracle RAC on kubeadm PoC)
text
cdrom
lang en_US.UTF-8
keyboard us
timezone America/New_York --utc
network --device=enp0s3 --bootproto=static --ip=10.0.1.5 --netmask=255.255.255.0 --gateway=10.0.1.1 --nameserver=8.8.8.8 --noipv6 --onboot=yes --activate
network --hostname=ol98-golden
rootpw --plaintext "$Pw" --allow-ssh
sshkey --username=root "$PubKey"
selinux --enforcing
firewall --disabled
firstboot --disabled
skipx
ignoredisk --only-use=sda
zerombr
clearpart --all --initlabel --drives=sda
reqpart --add-boot
part pv.01 --size=1 --grow --ondisk=sda
volgroup ol pv.01
logvol / --vgname=ol --name=root --fstype=xfs --size=1 --grow
reboot --eject

%packages
@^minimal-environment
chrony
tar
rsync
%end
"@
# LF line endings, UTF-8 without BOM (Anaconda is strict about both)
[IO.File]::WriteAllText($Ks, $ksText.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))

# --- 4. Unattended install ---
VB unattended install $Golden --iso=$Iso --script-template=$Ks `
   --hostname=ol98-golden.localdomain --user=rac --password=$Pw `
   --time-zone=America/New_York --locale=en_US --country=US --start-vm=gui
Remove-Item $Ks   # contains the password; VirtualBox has its own copy in the VM folder

# --- 5. Wait for the installed system to answer on SSH ---
Write-Host "`nInstalling. This usually takes 10-20 minutes. Waiting for SSH on 127.0.0.1:2205 ..."
$deadline = (Get-Date).AddMinutes(45)
# Windows PowerShell turns ssh's stderr into a terminating error when ErrorActionPreference is Stop
$ErrorActionPreference = "Continue"
do {
    Start-Sleep -Seconds 30
    ssh -p 2205 -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new `
        -i $KeyFile root@127.0.0.1 "true" 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    if (-not $ok) { Write-Host -NoNewline "." }
} until ($ok -or (Get-Date) -gt $deadline)
if (-not $ok) { throw "No SSH after 45 minutes. Check the VM console." }

Write-Host "`n`nInstalled and reachable. Quick check:"
ssh -p 2205 -i $KeyFile root@127.0.0.1 "cat /etc/oracle-release; uname -r; ip -br addr; lsblk; swapon --show; getenforce; ping -c2 yum.oracle.com"
Write-Host "`nNext: put rac-ocne.te next to these scripts, then run .\02b-prep-golden-remote.ps1"
