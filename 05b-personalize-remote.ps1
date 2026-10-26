# 05b-personalize-remote.ps1
# Phase 3 from Windows: starts each clone in turn, runs 05-personalize-node.sh over SSH,
# waits for it to come back on its own IP, then prints the post-checks.
# Run after 04-clone-nodes.ps1. Clones all boot as 10.0.1.5 (port 2205), so they are done
# strictly one at a time; a finished node has moved to its own IP before the next one starts.

$ErrorActionPreference = "Continue"   # ssh writes normal messages to stderr; exit codes are checked instead
$VBox    = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$KeyFile = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
$Nodes   = @(
    @{ Name = "controlplane"; Port = 2210 },
    @{ Name = "worker1";      Port = 2211 },
    @{ Name = "worker2";      Port = 2212 }
)
# Every clone has a fresh host key on 10.0.1.5, so don't record keys for the temporary address
$TempSsh = @("-p", "2205", "-i", $KeyFile, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3")

function Wait-Ssh([string[]]$SshArgs, [int]$Minutes = 10) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    do {
        Start-Sleep -Seconds 10
        ssh @SshArgs -o BatchMode=yes -o ConnectTimeout=5 root@127.0.0.1 "true" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host -NoNewline "." }
    } until ($LASTEXITCODE -eq 0 -or (Get-Date) -gt $deadline)
    Write-Host ""
    return ($LASTEXITCODE -eq 0)
}

$workerCheck = @'
echo "hostname:   $(hostname)   ip: $(ip -4 -br addr show enp0s3 | awk '{print $3}')"
echo "kernel:     $(uname -r)"
df -h --output=target,size /scratch /var/lib/containers | sed 's/^/disk:       /'
echo "hugepages:  $(awk '/HugePages_Total/{print $2}' /proc/meminfo)"
ls -dZ /scratch/rac/cluster01/* | sed 's/^/selinux:    /'
ip -br link show enp0s8 | sed 's/^/priv1:      /'
ip -br link show enp0s9 | sed 's/^/priv2:      /'
ls -l /dev/disk/by-id/ | grep -E ' ata-VBOX.*(sdd|sde)$' | awk '{print "asm-disk:   " $9 " -> " $11}'
echo "crio:       $(systemctl is-active crio)   images: $(crictl images -q 2>/dev/null | wc -l)"
'@
$cpCheck = @'
echo "hostname:   $(hostname)   ip: $(ip -4 -br addr show enp0s3 | awk '{print $3}')"
echo "kernel:     $(uname -r)"
echo "crio:       $(systemctl is-active crio)   images: $(crictl images -q 2>/dev/null | wc -l)"
'@

foreach ($n in $Nodes) {
    $name = $n.Name; $port = $n.Port
    Write-Host "`n==================== $name ===================="

    # Already personalized? (rerun-safe)
    ssh -p $port -i $KeyFile -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@127.0.0.1 "hostname" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "$name already answers on port $port, skipping personalize." }
    else {
        $state = (& $VBox showvminfo $name --machinereadable | Select-String '^VMState=').ToString()
        if ($state -notmatch '"running"') {
            for ($i = 1; $i -le 6; $i++) {
                & $VBox startvm $name --type headless 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { break }
                Start-Sleep -Seconds 10
            }
            if ($LASTEXITCODE -ne 0) { throw "Could not start $name" }
        }
        Write-Host "Waiting for $name on the temporary address 10.0.1.5 (port 2205)"
        if (-not (Wait-Ssh $TempSsh 10)) { throw "$name never answered on 10.0.1.5. Check its console." }

        $actual = ssh @TempSsh root@127.0.0.1 "cat /sys/class/dmi/id/product_name; hostname" 2>$null
        Write-Host "Connected to temporary host: $($actual -join ' / ')"

        # Always push the current 05-personalize-node.sh from this folder (the copy baked into the
        # golden image may be older)
        $Here = Split-Path -Parent $MyInvocation.MyCommand.Path
        scp -P 2205 -i $KeyFile -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
            (Join-Path $Here "05-personalize-node.sh") "root@127.0.0.1:/root/05-personalize-node.sh" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not copy 05-personalize-node.sh to $name" }

        # The script moves the node off 10.0.1.5 part-way through, which silently kills this SSH
        # session. So start it detached, log to a file, and watch for the node on its new address.
        ssh @TempSsh root@127.0.0.1 "tr -d '\r' < /root/05-personalize-node.sh > /root/05p.sh; setsid nohup bash /root/05p.sh $name > /root/personalize.log 2>&1 < /dev/null &" 2>&1 | Out-Null
        Write-Host "Personalize started on $name (log: /root/personalize.log)"

        ssh-keygen -R "[127.0.0.1]:$port" 2>&1 | Out-Null
        Write-Host "Waiting for $name on its own IP (port $port)"
        $own = @("-p", "$port", "-i", $KeyFile, "-o", "StrictHostKeyChecking=accept-new")
        if (-not (Wait-Ssh $own 10)) {
            Write-Host "$name did not come up on port $port. Its log, if it is still on 10.0.1.5:"
            ssh @TempSsh -o ConnectTimeout=5 root@127.0.0.1 "cat /root/personalize.log" 2>&1 | ForEach-Object { Write-Host $_ }
            throw "Personalize failed on $name. Nothing after this node was touched."
        }
        # The node answers on its new IP as soon as the network step runs, while disks are still
        # being formatted. Wait for the script to finish (it ends with a reboot) or to fail.
        Write-Host "Waiting for the personalize script to finish on $name"
        $deadline = (Get-Date).AddMinutes(20)
        $status = ""
        do {
            Start-Sleep -Seconds 10
            $status = ssh @own -o ConnectTimeout=5 root@127.0.0.1 "if grep -q '^ERROR' /root/personalize.log; then echo FAILED; elif grep -q 'Rebooting' /root/personalize.log; then echo REBOOTING; elif pgrep -f 05p.sh >/dev/null; then echo RUNNING; else echo DONE; fi" 2>$null
            if ($status -eq "RUNNING") { Write-Host -NoNewline "." }
        } until ($status -in @("FAILED", "REBOOTING", "DONE") -or (Get-Date) -gt $deadline)
        Write-Host ""
        Write-Host "--- personalize log: $name ---"
        ssh @own root@127.0.0.1 "cat /root/personalize.log" 2>&1 | ForEach-Object { Write-Host $_ }
        if ($status -ne "REBOOTING" -and $status -ne "DONE") { throw "Personalize did not finish cleanly on $name (status: $status)." }

        Write-Host "Waiting for $name to reboot"
        Start-Sleep -Seconds 30
        if (-not (Wait-Ssh $own 10)) { throw "$name did not come back after its reboot. Check its console." }
    }

    Write-Host "--- checks: $name ---"
    $check = if ($name -eq "controlplane") { $cpCheck } else { $workerCheck }
    $check | ssh -p $port -i $KeyFile root@127.0.0.1 "tr -d '\r' | bash -s"
}

Write-Host "`nAll three nodes personalized. The two asm-disk lines must show the same IDs on worker1 and worker2."
Write-Host "Next: Phase 5 (kubeadm) on controlplane:  ssh -p 2210 root@127.0.0.1"
