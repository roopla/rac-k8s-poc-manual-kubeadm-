# 00-build-all.ps1
# Builds the whole Oracle RAC on kubeadm PoC lab on VirtualBox, from the Oracle Linux ISO to a
# validated 3-node cluster (controlplane, worker1, worker2) with Flannel + Multus and the RAC
# interconnect tested. Includes every fix found during the first manual build.
#
# Usage (PowerShell, from this folder):
#   .\00-build-all.ps1                 # full build; safe to rerun, finished stages are skipped
#   .\00-build-all.ps1 -From 6         # resume from a stage
#   .\00-build-all.ps1 -RebootTest     # also reboot both workers at the end and retest
#
# Stages:
#   0 Preflight          4 Clone nodes + disks       8 ASM volume file
#   1 Networks + VM      5 Personalize nodes         9 Validation report
#   2 Install OS         6 kubeadm + Flannel + join
#   3 Prepare + seal     7 Multus + interconnect test
#
# Before the first run:  ssh-keygen -t ed25519   (Enter at every prompt), and check the
# SETTINGS block in lab-common.ps1 (VirtualBox path, VM folder, ISO path).
# Time: about 60-90 minutes on first run, mostly the OS install and dnf downloads.

param(
    [ValidateRange(0, 9)][int]$From = 0,
    [switch]$RebootTest
)

. "$PSScriptRoot\lab-common.ps1"
$started = Get-Date
$goldenFiles = @("02-prep-golden.sh", "03-seal-golden.sh", "05-personalize-node.sh", "06-kubeadm-config.yaml",
                 "07-multus-rac-nad.yaml", "08-test-multus-pods.yaml", "node-validate.sh", "rac-ocne.te") |
               ForEach-Object { Join-Path $Here $_ }

function Test-AllClones { return (@($Nodes | Where-Object { Test-Vm $_.Name }).Count -eq $Nodes.Count) }

function Run-Stage([int]$n, [string]$title, [scriptblock]$body) {
    if ($n -lt $From) { Info "Stage $n ($title): skipped by -From $From"; return }
    Say "Stage $n - $title"
    & $body
}

function Test-Interconnect {
    Info "Interconnect test: pods on worker1 and worker2, eth1/eth2 on rac-priv1/rac-priv2"
    Invoke-Remote $CpPort @'
set -e
kubectl delete -f /root/08-test-multus-pods.yaml --ignore-not-found --wait >/dev/null
kubectl apply -f /root/08-test-multus-pods.yaml >/dev/null
kubectl -n multus-rac wait --for=condition=Ready pod/nettest-w1 pod/nettest-w2 --timeout=300s >/dev/null
fail=0
for p in w1:148 w2:149; do
  pod=nettest-${p%%:*}; o=${p##*:}
  a1=$(kubectl -n multus-rac exec $pod -- ip -o -f inet addr show eth1 | awk '{print $4}')
  a2=$(kubectl -n multus-rac exec $pod -- ip -o -f inet addr show eth2 | awk '{print $4}')
  echo "$pod: eth1=$a1 eth2=$a2"
  [[ $a1 == 10.0.11.$o/24 && $a2 == 10.0.12.$o/24 ]] || { echo "  requested IPs not assigned"; fail=1; }
done
for t in 10.0.11.149 10.0.12.149; do
  if kubectl -n multus-rac exec nettest-w1 -- ping -c3 -W2 $t >/dev/null; then echo "ping worker1 -> $t: OK"; else echo "ping worker1 -> $t: FAILED"; fail=1; fi
done
for t in 10.0.11.148 10.0.12.148; do
  if kubectl -n multus-rac exec nettest-w2 -- ping -c3 -W2 $t >/dev/null; then echo "ping worker2 -> $t: OK"; else echo "ping worker2 -> $t: FAILED"; fail=1; fi
done
kubectl delete -f /root/08-test-multus-pods.yaml --wait >/dev/null
exit $fail
'@
    Ok "Interconnect works in both directions on both private networks (test pods removed)"
}

try {
# ------------------------------------------------------------------------------------
Run-Stage 0 "Preflight" {
    if (-not (Test-Path $Lab.VBox)) { throw "VBoxManage not found at $($Lab.VBox). Fix the path in lab-common.ps1." }
    if (-not (Test-Path "$($Lab.KeyFile).pub")) { throw "No SSH key at $($Lab.KeyFile). Run: ssh-keygen -t ed25519  (Enter at every prompt)" }
    foreach ($f in $goldenFiles + (Join-Path $Here "09-asm-pv.template.yaml")) { if (-not (Test-Path $f)) { throw "Missing file: $f" } }
    if (-not (Test-Vm $Lab.Golden) -and -not (Test-Path $Lab.Iso)) { throw "ISO not found: $($Lab.Iso). Fix the path in lab-common.ps1." }
    Ok "Files, SSH key and VirtualBox found"

    $threads = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    if ($Lab.WorkerCpus -eq 0) { $Lab.WorkerCpus = if ($threads -ge 16) { 6 } elseif ($threads -ge 12) { 5 } else { 4 } }
    $podCpu = [Math]::Min(4, $Lab.WorkerCpus - 1)
    Ok "Host has $threads logical CPUs -> workers get $($Lab.WorkerCpus) vCPU; use cpu: `"$podCpu`" for the RAC pods"

    $ramGB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $needGB = [Math]::Round(($Lab.CpMemMB + 2 * $Lab.WorkerMemMB) / 1024) + 8
    if ($ramGB -lt $needGB) { Warn "Host has $ramGB GB RAM; VMs need $([Math]::Round(($Lab.CpMemMB + 2*$Lab.WorkerMemMB)/1024)) GB plus room for Windows" }
    else { Ok "Host RAM $ramGB GB" }

    $drive = Split-Path -Qualifier $Lab.BaseDir
    $freeGB = [Math]::Round((Get-PSDrive $drive.TrimEnd(':')).Free / 1GB)
    if (-not (Test-Vm "worker1") -and $freeGB -lt 150) { throw "Only $freeGB GB free on $drive; need about 150 GB now, 250 GB over the PoC" }
    Ok "Free disk on ${drive}: $freeGB GB"
}

# ------------------------------------------------------------------------------------
Run-Stage 1 "VirtualBox networks and golden VM" {
    $nn = (& $Lab.VBox natnetwork list 2>$null) -join "`n"
    if ($nn -notmatch "Name:\s+$($Lab.NatNet)\b") {
        VB natnetwork add --netname $Lab.NatNet --network "10.0.1.0/24" --enable --dhcp off
        Ok "NAT Network $($Lab.NatNet) created (10.0.1.0/24, DHCP off)"
    } else { Ok "NAT Network $($Lab.NatNet) exists" }
    $nn = (& $Lab.VBox natnetwork list 2>$null) -join "`n"
    $rules = @{ "ssh-golden" = "2205:[10.0.1.5]"; "ssh-cp" = "2210:[10.0.1.10]"; "ssh-w1" = "2211:[10.0.1.11]"; "ssh-w2" = "2212:[10.0.1.12]" }
    foreach ($r in $rules.Keys) {
        if ($nn -notmatch "\b$r\b") {
            $hp, $guest = $rules[$r] -split ':', 2
            VB natnetwork modify --netname $Lab.NatNet --port-forward-4 "${r}:tcp:[]:${hp}:${guest}:22"
        }
    }
    & $Lab.VBox natnetwork start --netname $Lab.NatNet 2>&1 | Out-Null   # fails harmlessly if already running
    Ok "SSH port forwards 2205, 2210, 2211, 2212"

    if (Test-Vm $Lab.Golden) { Ok "VM $($Lab.Golden) exists"; return }
    New-Item -ItemType Directory -Force -Path $Lab.BaseDir | Out-Null
    $g = $Lab.Golden
    VB createvm --name $g --ostype Oracle_64 --basefolder $Lab.BaseDir --register
    VB modifyvm $g --cpus 2 --memory 4096 --vram 16 --graphicscontroller vmsvga --ioapic on --paravirtprovider kvm --rtcuseutc on --boot1 dvd --boot2 disk --boot3 none --boot4 none
    VB modifyvm $g --nic1 natnetwork --nat-network1 $Lab.NatNet
    VB modifyvm $g --nic2 intnet --intnet2 rac-priv1 --nicpromisc2 allow-all
    VB modifyvm $g --nic3 intnet --intnet3 rac-priv2 --nicpromisc3 allow-all
    $os = Join-Path (Join-Path $Lab.BaseDir $g) "$g-os.vdi"
    VB storagectl $g --name SATA --add sata --controller IntelAhci --portcount 6 --hostiocache off
    VB createmedium disk --filename $os --size 51200 --variant Standard
    VB storageattach $g --storagectl SATA --port 0 --device 0 --type hdd --medium $os
    VB storageattach $g --storagectl SATA --port 5 --device 0 --type dvddrive --medium $Lab.Iso
    Ok "VM $g created: 2 vCPU, 4 GB, 50 GB disk, NIC1 $($Lab.NatNet), NIC2/3 rac-priv1/2 (allow-all), KVM paravirt"
}

# ------------------------------------------------------------------------------------
Run-Stage 2 "Unattended Oracle Linux install" {
    $g = $Lab.Golden
    if (Test-AllClones) { Ok "All three nodes already exist; golden image not needed"; return }
    if ((Get-Extra $g "racpoc/installed") -eq "1") { Ok "OS already installed"; return }
    if ((Get-VmState $g) -eq "running" -and (Test-Ssh $GoldenPort)) { Set-Extra $g "racpoc/installed" "1"; Ok "OS already installed (answers on SSH)"; return }
    if ((Get-VmState $g) -eq "running") { throw "$g is running but not answering on SSH. Check its console, or power it off and rerun." }

    $sec = Read-Host "Root password for all lab VMs (8+ chars, no spaces or double quotes)" -AsSecureString
    $pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if ($pw -match '[" ]' -or $pw.Length -lt 8) { throw "Use 8+ characters with no spaces or double quotes." }
    $pub = (Get-Content "$($Lab.KeyFile).pub" -Raw).Trim()

    $ks = @"
# Kickstart for $g (Oracle RAC on kubeadm PoC)
text
cdrom
lang en_US.UTF-8
keyboard us
timezone America/New_York --utc
network --device=enp0s3 --bootproto=static --ip=10.0.1.5 --netmask=255.255.255.0 --gateway=10.0.1.1 --nameserver=8.8.8.8 --noipv6 --onboot=yes --activate
network --hostname=$g
rootpw --plaintext "$pw" --allow-ssh
sshkey --username=root "$pub"
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
    $ksFile = Join-Path $Here "ol98-golden-ks.cfg"
    [IO.File]::WriteAllText($ksFile, $ks.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
    try {
        VB unattended install $g "--iso=$($Lab.Iso)" "--script-template=$ksFile" --hostname=ol98-golden.localdomain --user=rac "--password=$pw" --time-zone=America/New_York --locale=en_US --country=US --start-vm=headless
    } finally { Remove-Item $ksFile -ErrorAction SilentlyContinue }
    Info "Installing (10-20 minutes). Watch it in VirtualBox Manager > $g > Show if you like."
    if (-not (Wait-Ssh $GoldenPort 45)) { throw "No SSH from $g after 45 minutes. Check its console." }
    Set-Extra $g "racpoc/installed" "1"
    Invoke-Remote $GoldenPort 'cat /etc/oracle-release; uname -r; ip -4 -br addr show enp0s3; swapon --show | wc -l; getenforce'
    Ok "Oracle Linux installed"
}

# ------------------------------------------------------------------------------------
Run-Stage 3 "Prepare and seal the golden image" {
    $g = $Lab.Golden
    if (Test-AllClones) { Ok "All three nodes already exist; golden image not needed"; return }
    if ((Get-Extra $g "racpoc/sealed") -eq "1") { Ok "Golden image already prepared and sealed"; return }

    if ((Get-Extra $g "racpoc/prepped") -ne "1") {
        Start-Vm $g
        if (-not (Wait-Ssh $GoldenPort 10)) { throw "$g not answering on SSH" }
        Copy-ToVm $GoldenPort $goldenFiles
        Info "Running 02-prep-golden.sh (15-25 minutes; output follows)"
        Invoke-RemoteStream $GoldenPort ("export K8S_MINOR=$($Lab.K8sMinor) CRIO_MINOR=$($Lab.CrioMinor); " + 'set -o pipefail; bash /root/02-prep-golden.sh 2>&1 | tee /root/02-prep-golden.log')
        Invoke-Remote $GoldenPort 'systemctl reboot' -AllowFail -Quiet
        Start-Sleep -Seconds 20
        if (-not (Wait-Ssh $GoldenPort 10)) { throw "$g did not come back after reboot" }
        Invoke-Remote $GoldenPort @'
fail=0
k=$(uname -r);        echo "kernel:      $k";   [[ $k == 5.15.0-*el9uek* ]] || fail=1
t=$(cat /sys/kernel/mm/transparent_hugepage/enabled); echo "THP:         $t"; [[ $t == *"[madvise]"* ]] || fail=1
echo "clocksource: $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
s=$(swapon --noheadings | wc -l); echo "swap:        $s"; [[ $s -eq 0 ]] || fail=1
e=$(getenforce);      echo "selinux:     $e";   [[ $e == Enforcing ]] || fail=1
semodule -l | grep -qw rac-ocne && echo "rac-ocne:    loaded" || { echo "rac-ocne:    MISSING"; fail=1; }
c=$(systemctl is-active crio); echo "crio:        $c"; [[ $c == active ]] || fail=1
n=$(crictl images -q | wc -l); echo "images:      $n";  [[ $n -ge 7 ]] || fail=1
echo "pause:       $(grep -h pause_image /etc/crio/crio.conf.d/*.conf 2>/dev/null)"
echo "kubeadm:     $(kubeadm version -o short)"
exit $fail
'@
        Set-Extra $g "racpoc/prepped" "1"
        Ok "Golden image prepared and verified"
    }

    if ((Get-VmState $g) -eq "running") {
        Invoke-Remote $GoldenPort 'systemctl poweroff' -AllowFail -Quiet
        Wait-VmState $g "poweroff" 180
    }
    Clear-DvdDrives $g
    if (-not (Test-Snapshot $g "pre-seal")) { VB snapshot $g take pre-seal --description "Prepared golden image before sealing"; Ok "Snapshot pre-seal taken" }
    Start-Vm $g
    if (-not (Wait-Ssh $GoldenPort 10)) { throw "$g not answering on SSH before sealing" }
    Invoke-Remote $GoldenPort 'bash /root/03-seal-golden.sh' -AllowFail -Quiet
    Wait-VmState $g "poweroff" 180
    Set-Extra $g "racpoc/sealed" "1"
    Ok "Golden image sealed and powered off"
}

# ------------------------------------------------------------------------------------
Run-Stage 4 "Clone nodes, add worker disks and shared ASM disks" {
    $g = $Lab.Golden
    if (-not (Test-AllClones)) {
        if ((Get-Extra $g "racpoc/sealed") -ne "1") { throw "Golden image is not sealed; run stage 3 first" }
        if ((Get-VmState $g) -ne "poweroff") { throw "$g must be powered off before cloning" }
    }
    if ($Lab.WorkerCpus -eq 0) {   # when resuming with -From 4 or later
        $threads = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        $Lab.WorkerCpus = if ($threads -ge 16) { 6 } elseif ($threads -ge 12) { 5 } else { 4 }
    }
    foreach ($n in $Nodes) {
        $name = $n.Name
        if (Test-Vm $name) { Ok "$name exists"; continue }
        VB clonevm $g --name $name --basefolder $Lab.BaseDir --mode machine --register
        if ($n.Role -eq "cp") {
            VB modifyvm $name --cpus $Lab.CpCpus --memory $Lab.CpMemMB --nic2 none --nic3 none
        } else {
            VB modifyvm $name --cpus $Lab.WorkerCpus --memory $Lab.WorkerMemMB
            $dir = Join-Path $Lab.BaseDir $name
            $scratch = Join-Path $dir "$name-scratch.vdi"
            $cont = Join-Path $dir "$name-containers.vdi"
            VB createmedium disk --filename $scratch --size 81920 --variant Standard
            VB createmedium disk --filename $cont --size 102400 --variant Standard
            VB storageattach $name --storagectl SATA --port 1 --device 0 --type hdd --medium $scratch
            VB storageattach $name --storagectl SATA --port 2 --device 0 --type hdd --medium $cont
        }
        Ok "$name cloned and sized"
    }
    $shared = Join-Path $Lab.BaseDir "shared"
    New-Item -ItemType Directory -Force -Path $shared | Out-Null
    $port = 3
    foreach ($d in "asm1", "asm2") {
        $f = Join-Path $shared "$d.vdi"
        if (-not (Test-Path $f)) {
            Info "Creating $d.vdi (50 GB, fixed size: takes a few minutes)"
            VB createmedium disk --filename $f --size 51200 --variant Fixed
            VB modifymedium disk $f --type shareable
        }
        foreach ($w in $Workers) {
            $cur = Get-VmInfo $w.Name | Where-Object { $_ -like "`"SATA-$port-0`"=*" }
            if ("$cur" -notlike "*$d.vdi*") {
                VB storageattach $w.Name --storagectl SATA --port $port --device 0 --type hdd --medium $f --mtype shareable
            }
        }
        Ok "$d.vdi shared by worker1 and worker2 (SATA port $port)"
        $port++
    }
}

# ------------------------------------------------------------------------------------
Run-Stage 5 "Personalize nodes (one at a time on 10.0.1.5)" {
    foreach ($n in $Nodes) {
        $name = $n.Name; $port = $n.Port
        $h = Get-Remote $port 'hostname'
        if ($h -contains $name) { Ok "$name already personalized ($($n.Ip))"; continue }

        if ((Get-VmState $name) -ne "running" -and (Test-Ssh $GoldenPort)) {
            throw "Something else is already answering on 10.0.1.5 (port $GoldenPort). Power off unfinished clones and rerun."
        }
        Start-Vm $name
        Info "Waiting for $name on the temporary address 10.0.1.5"
        if (-not (Wait-Ssh $GoldenPort 10)) { throw "$name never answered on 10.0.1.5. Check its console." }
        $h = Get-Remote $GoldenPort 'hostname'
        if ($h -notcontains $Lab.Golden -and $h -notcontains $name) { throw "Port 2205 answered as '$h', not a fresh clone. Stopping." }

        # Push the current script (fixes: profile cleanup, disks by size, promiscuous private NICs)
        Copy-ToVm $GoldenPort @((Join-Path $Here "05-personalize-node.sh"), (Join-Path $Here "node-validate.sh"))
        # Run detached: the script moves the node off 10.0.1.5, which kills this SSH session
        Invoke-Remote $GoldenPort ("setsid nohup bash /root/05-personalize-node.sh $name > /root/personalize.log 2>&1 < /dev/null &") -Quiet
        Info "Personalize running on $name; waiting for it on $($n.Ip)"
        if (-not (Wait-Ssh $port 10)) {
            Warn "$name did not move to $($n.Ip). Log from 10.0.1.5:"
            Invoke-Remote $GoldenPort 'cat /root/personalize.log' -AllowFail
            throw "Personalize failed on $name"
        }
        # The new IP is live before the disks are done; wait for the script to finish or fail
        $deadline = (Get-Date).AddMinutes(20); $status = ""
        do {
            Start-Sleep -Seconds 10
            $status = "$(Get-Remote $port 'if grep -q ^ERROR /root/personalize.log; then echo FAILED; elif grep -q Rebooting /root/personalize.log; then echo REBOOTING; elif pgrep -f 05-personalize-node.sh >/dev/null; then echo RUNNING; else echo STOPPED; fi')".Trim()
            if ($status -eq "RUNNING") { Write-Host -NoNewline "." }
        } until ($status -in @("FAILED", "REBOOTING", "STOPPED") -or (Get-Date) -gt $deadline)
        Write-Host ""
        Invoke-Remote $port 'cat /root/personalize.log' -AllowFail
        if ($status -ne "REBOOTING") { throw "Personalize did not finish on $name (status: $status). See the log above." }
        Start-Sleep -Seconds 30
        if (-not (Wait-Ssh $port 10)) { throw "$name did not come back after its reboot" }
        Ok "$name personalized and rebooted"
    }
}

# ------------------------------------------------------------------------------------
Run-Stage 6 "kubeadm init, Flannel, join workers" {
    foreach ($n in $Nodes) { if (-not (Wait-Ssh $n.Port 5)) { throw "$($n.Name) is not answering on port $($n.Port)" } }

    $hasCluster = (Get-Remote $CpPort 'test -f /etc/kubernetes/admin.conf && echo yes') -contains "yes"
    if (-not $hasCluster) {
        Info "kubeadm init (1-2 minutes)"
        Invoke-RemoteStream $CpPort 'kubeadm init --config /root/06-kubeadm-config.yaml 2>&1 | grep -E "^\[(init|preflight|control-plane-check|kubelet-check|addons)\]|initialized successfully|^W|error"; test -f /etc/kubernetes/admin.conf'
    } else { Ok "Control plane already initialized" }
    Invoke-Remote $CpPort 'mkdir -p ~/.kube && cp -f /etc/kubernetes/admin.conf ~/.kube/config' -Quiet

    Invoke-Remote $CpPort ("kubectl apply -f $($Lab.FlannelUrl) >/dev/null && echo 'Flannel applied'")

    foreach ($w in $Workers) {
        $joined = (Get-Remote $CpPort "kubectl get node $($w.Name) -o name 2>/dev/null") -contains "node/$($w.Name)"
        if ($joined) { Ok "$($w.Name) already joined"; continue }
        $join = (Get-Remote $CpPort 'kubeadm token create --print-join-command') | Where-Object { $_ -like 'kubeadm join*' } | Select-Object -First 1
        if (-not $join) { throw "Could not get a join command from controlplane" }
        Invoke-Remote $w.Port "$join > /tmp/join.log 2>&1; rc=`$?; grep 'has joined' /tmp/join.log || cat /tmp/join.log; exit `$rc"
        Ok "$($w.Name) joined"
    }
    Invoke-Remote $CpPort ('kubectl label node ' + (($Workers | ForEach-Object { $_.Name }) -join ' ') + ' node-role.kubernetes.io/worker= --overwrite >/dev/null')
    Info "Waiting for all nodes to be Ready"
    Invoke-Remote $CpPort 'kubectl wait --for=condition=Ready node --all --timeout=600s >/dev/null && kubectl get nodes -o wide'
    Ok "Cluster up"
}

# ------------------------------------------------------------------------------------
Run-Stage 7 "Multus, RAC private networks and interconnect test" {
    Copy-ToVm $CpPort @((Join-Path $Here "07-multus-rac-nad.yaml"), (Join-Path $Here "08-test-multus-pods.yaml"))
    Invoke-Remote $CpPort ("kubectl apply -f $($Lab.MultusUrl) >/dev/null && kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=300s")
    Invoke-Remote $CpPort @'
kubectl create namespace multus-rac --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f /root/07-multus-rac-nad.yaml
kubectl get network-attachment-definitions -n multus-rac
'@
    Ok "Multus running on every node; macvlan-conf1 and macvlan-conf2 created"
    Test-Interconnect
}

# ------------------------------------------------------------------------------------
Run-Stage 8 "ASM volume file with this build's disk IDs" {
    # VirtualBox derives the guest disk serial from the VDI UUID: ata-VBOX_HARDDISK_VB<first 8 hex>-...
    $ids = @{}
    foreach ($d in "asm1", "asm2") {
        $f = Join-Path (Join-Path $Lab.BaseDir "shared") "$d.vdi"
        $uuidLine = (& $Lab.VBox showmediuminfo disk $f 2>$null) | Where-Object { $_ -match '^UUID:' } | Select-Object -First 1
        if ($uuidLine -notmatch 'UUID:\s+([0-9a-f]{8})') { throw "Could not read the UUID of $f" }
        $prefix = "ata-VBOX_HARDDISK_VB$($Matches[1])-"
        $found = @()
        foreach ($w in $Workers) {
            $found += , (Get-Remote $w.Port ("ls /dev/disk/by-id/ | grep '^$prefix' | grep -v -- -part"))
        }
        $id1 = "$($found[0])".Trim(); $id2 = "$($found[1])".Trim()
        if (-not $id1 -or $id1 -ne $id2) { throw "$d not seen with the same ID on both workers (worker1: '$id1', worker2: '$id2')" }
        $ids[$d] = $id1
        Ok "$d = $id1 on both workers"
    }
    $tpl = Get-Content (Join-Path $Here "09-asm-pv.template.yaml") -Raw
    $yaml = $tpl.Replace("__ASM1_ID__", $ids["asm1"]).Replace("__ASM2_ID__", $ids["asm2"]).Replace("# TEMPLATE: 00-build-all.ps1 writes 09-asm-pv.yaml from this file with the real disk IDs.", "# Generated by 00-build-all.ps1 for this build's shared disks.")
    $out = Join-Path $Here "09-asm-pv.yaml"
    [IO.File]::WriteAllText($out, $yaml.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
    Copy-ToVm $CpPort @($out)
    Ok "Wrote 09-asm-pv.yaml and copied it to controlplane:/root (applied in Phase 6, not now)"
}

if ($RebootTest -and 8 -ge $From) {
    Say "Reboot test - restart both workers and retest"
    foreach ($w in $Workers) { Invoke-Remote $w.Port 'systemctl reboot' -AllowFail -Quiet }
    Start-Sleep -Seconds 45
    foreach ($w in $Workers) { if (-not (Wait-Ssh $w.Port 10)) { throw "$($w.Name) did not come back" } }
    Invoke-Remote $CpPort 'sleep 30; kubectl wait --for=condition=Ready node --all --timeout=600s >/dev/null; kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=300s >/dev/null; kubectl -n kube-flannel rollout status ds/kube-flannel-ds --timeout=300s >/dev/null; kubectl get nodes'
    Test-Interconnect
}

# ------------------------------------------------------------------------------------
Run-Stage 9 "Validation report" {
    & (Join-Path $Here "90-validate.ps1")
    if ($LASTEXITCODE -ne 0) { throw "Validation found failures (see the report above)" }
}

$mins = [Math]::Round(((Get-Date) - $started).TotalMinutes)
Say "Done in $mins minutes"
Info "Cluster ready. SSH: controlplane 2210, worker1 2211, worker2 2212 (ssh -p 2210 root@127.0.0.1)"
Info "Next: Phase 6 of the guide (RAC image, rac namespace, kubectl apply -f /root/09-asm-pv.yaml)"
}
catch {
    Write-Host "`nSTOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Fix the cause, then rerun .\00-build-all.ps1 (finished stages are skipped)." -ForegroundColor Yellow
    exit 1
}
