# 01-create-golden-vm.ps1
# Creates the VirtualBox networks and the golden VM for the Oracle RAC on kubeadm PoC.
# Run in PowerShell on the Windows host. Written for VirtualBox 7.x.
# Edit the three paths below before running.

$ErrorActionPreference = "Stop"
$VBox   = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$Base   = "D:\VMs\rac-poc"                                  # where VM folders and disks go
$Iso    = "D:\ISO\OracleLinux-R9-U8-x86_64-dvd.iso"         # Oracle Linux 9.8 full DVD ISO
$Golden = "ol98-golden"

function VB { & $VBox @args; if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ') failed" } }

New-Item -ItemType Directory -Force -Path $Base | Out-Null

# --- 1. NAT Network for node/public traffic (DHCP off: all IPs are static) ---
VB natnetwork add --netname k8s-public --network "10.0.1.0/24" --enable --dhcp off
VB natnetwork modify --netname k8s-public --port-forward-4 "ssh-golden:tcp:[]:2205:[10.0.1.5]:22"
VB natnetwork modify --netname k8s-public --port-forward-4 "ssh-cp:tcp:[]:2210:[10.0.1.10]:22"
VB natnetwork modify --netname k8s-public --port-forward-4 "ssh-w1:tcp:[]:2211:[10.0.1.11]:22"
VB natnetwork modify --netname k8s-public --port-forward-4 "ssh-w2:tcp:[]:2212:[10.0.1.12]:22"
VB natnetwork start --netname k8s-public

# --- 2. Golden VM ---
VB createvm --name $Golden --ostype Oracle_64 --basefolder $Base --register
VB modifyvm $Golden --cpus 2 --memory 4096 --vram 16 --graphicscontroller vmsvga `
   --ioapic on --paravirtprovider kvm --rtcuseutc on `
   --boot1 dvd --boot2 disk --boot3 none --boot4 none

# Adapter 1 -> enp0s3 (public / Flannel)
VB modifyvm $Golden --nic1 natnetwork --nat-network1 k8s-public
# Adapters 2,3 -> enp0s8, enp0s9 (RAC private, macvlan needs promiscuous Allow All)
VB modifyvm $Golden --nic2 intnet --intnet2 rac-priv1 --nicpromisc2 allow-all
VB modifyvm $Golden --nic3 intnet --intnet3 rac-priv2 --nicpromisc3 allow-all

# --- 3. Storage: SATA controller, 50 GB thin OS disk, ISO ---
$VmDir  = Join-Path $Base $Golden
$OsDisk = Join-Path $VmDir "$Golden-os.vdi"
VB storagectl $Golden --name SATA --add sata --controller IntelAhci --portcount 6 --hostiocache off
VB createmedium disk --filename $OsDisk --size 51200 --variant Standard
VB storageattach $Golden --storagectl SATA --port 0 --device 0 --type hdd --medium $OsDisk
VB storageattach $Golden --storagectl SATA --port 5 --device 0 --type dvddrive --medium $Iso

Write-Host "`nGolden VM '$Golden' created. Start it with:"
Write-Host "  & '$VBox' startvm $Golden --type gui"
