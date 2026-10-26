# Oracle RAC 19c on kubeadm: VirtualBox PoC lab

One command builds the whole lab on a Windows host with VirtualBox, from the Oracle Linux 9.8 ISO to a
validated three-node cluster:

- **controlplane** 10.0.1.10
- **worker1** 10.0.1.11
- **worker2** 10.0.1.12

The finished cluster has Kubernetes v1.36 with CRI-O, Flannel and Multus. The RAC private networks are
tested between the workers, and the two ASM disks are shared by both workers. That is the starting
point for Phase 6 of the build guide.

## Files

| File | Runs on | Purpose |
| --- | --- | --- |
| `00-build-all.ps1` | Windows | Builds everything, stage by stage; safe to rerun |
| `90-validate.ps1` | Windows | Health report for all nodes and the cluster; run any time |
| `99-destroy-lab.ps1` | Windows | Deletes the lab so you can rebuild (asks for confirmation) |
| `10-rac-image-and-asm.ps1` | Windows | Phase 6: RAC image, ASM volumes, smoke-test pod |
| `rac-image/Containerfile`, `rac-image/setupContainerEnv.sh` | worker1 | The doc's RAC pod image, built from Oracle Linux 9 |
| `11-rac-smoke-pod.yaml` | controlplane | Smoke-test pod with the doc's RAC pod settings |
| `12-rac-pods.ps1` | Windows | RAC pods: SSH key secret, headless services, both StatefulSets, readiness checks |
| `rac/racnode-svc.yaml`, `rac/rac1_sts.yaml`, `rac/rac2_sts.yaml` | controlplane | The doc's RAC services and StatefulSets with this PoC's changes |
| `13-grid-install.ps1` | Windows | Grid Infrastructure 19.32 in the RAC pods (resumable) |
| `rac/racnode-np-svc.yaml`, `rac/dbclient.yaml`, `rac/scan-test.sh`, `scan_test.py` | controlplane / pod / Windows | Phase 11: NodePort services (doc, unchanged), client pod, SCAN tests inside and outside the cluster |
| `15-pod-persistence.ps1`, `rac/restart-state/snapshot.sh`, `rac/restart-state/onstart.sh` | Windows / RAC pods | Phase 12: saves Grid's files outside `/u01` into `/u01` and restores them when a pod is recreated |
| `rac/gi.rsp.template` | racnode1-0 | Grid response file; the password is filled in only inside the pod |
| `14-db-install.ps1` | Windows | RAC database 19.32: DB software, root.sh, dbca ORCLCDB/ORCLPDB, service, checks (resumable) |
| `lab-common.ps1` | Windows | Settings (paths, sizes) and helpers used by the three scripts above |
| `02-prep-golden.sh` | golden VM | OS prep: UEK R7, sysctls, SELinux module, CRI-O, kubeadm, crictl |
| `03-seal-golden.sh` | golden VM | Clears the machine identity before cloning |
| `05-personalize-node.sh` | each clone | Hostname, IP, private NICs, data disks, hugepages, `/scratch` directories |
| `node-validate.sh` | each node | Read-only checks used by `90-validate.ps1` |
| `06-kubeadm-config.yaml` | controlplane | kubeadm settings, including the unsafe sysctls RAC pods need |
| `07-multus-rac-nad.yaml` | controlplane | The two macvlan RAC private networks |
| `08-test-multus-pods.yaml` | controlplane | Throwaway pods for the interconnect test |
| `09-asm-pv.template.yaml` | Windows | Template; the build writes `09-asm-pv.yaml` with this build's disk IDs |
| `rac-ocne.te` | golden VM | SELinux policy module for the RAC pods |

## Before the first run

1. Install VirtualBox 7.x. If you can, turn off Hyper-V, WSL2 and Memory Integrity, so VirtualBox
   uses its own hypervisor.
2. Create an SSH key: `ssh-keygen -t ed25519`, then press Enter at every prompt.
3. Edit the **SETTINGS** block at the top of `lab-common.ps1`: the VirtualBox path, the VM folder and
   the ISO path.
4. If PowerShell blocks the scripts, run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once.

## Run

```powershell
cd D:\rac-k8s-poc
.\00-build-all.ps1
```

The script asks for a root password once, at the start of stage 2. The first run takes about 60–90
minutes. It ends with the validation report.

| Stage | What it does | Main checks |
| --- | --- | --- |
| 0 | Preflight | Files, SSH key, ISO, free disk (150 GB or more), RAM; picks worker vCPUs from the host's thread count |
| 1 | NAT Network `k8s-public`, SSH port forwards, golden VM | |
| 2 | Unattended Oracle Linux install from a generated kickstart | SSH answers on 10.0.1.5 |
| 3 | Runs `02-prep-golden.sh`, reboots, snapshots `pre-seal`, seals | UEK R7, THP madvise, no swap, SELinux Enforcing, `rac-ocne` module, CRI-O, 7 images |
| 4 | Three full clones, worker data disks, two fixed shareable ASM disks | |
| 5 | Personalizes each clone in turn | Script finished and rebooted; node answers on its own IP |
| 6 | `kubeadm init`, Flannel, worker join | All nodes Ready |
| 7 | Multus, RAC networks, interconnect test | Requested IPs assigned; ping both ways on both networks |
| 8 | Writes `09-asm-pv.yaml` with the real by-id disk names | Same IDs seen on both workers |
| 9 | Validation report | About 25 checks per worker, plus cluster checks |

Options:

- `.\00-build-all.ps1 -From 6` resumes from a stage.
- `.\00-build-all.ps1 -RebootTest` also reboots both workers at the end and repeats the interconnect test.

If a stage fails, fix the cause and rerun the same command. Finished stages are detected and
skipped. The golden image's progress is recorded as VirtualBox extradata (`racpoc/installed`,
`racpoc/prepped`, `racpoc/sealed`).

## After the build: Phase 6 and Phase 7

### Phase 6: RAC image, ASM volumes, smoke test

```powershell
.\10-rac-image-and-asm.ps1            # about 10 minutes; -Rebuild forces a new image
```

| Section | What it does |
| --- | --- |
| 1 | Builds `localhost/oracle/database-rac:19-ol9-slim` on worker1 from `rac-image/Containerfile` (Oracle Linux 9, the doc's recipe, no Oracle software) |
| 2 | Copies the image straight from worker1 to worker2 over 10.0.1.x |
| 3 | Checks the image contents |
| 4 | Creates the `rac` namespace and the ASM PVs and PVCs from `09-asm-pv.yaml` |
| 5 | Runs a smoke-test pod with the doc's RAC pod settings, checks it, then deletes it |

### Phase 7: stage the Oracle software (19.32 gold images)

worker1 downloads the zips from this PC; pushing them in through the SSH port forward is far too slow.

```bash
# Git Bash: serve only the zips, then leave this window running
mkdir -p ~/Downloads/oracle-stage && mv ~/Downloads/oracle-*-19.32.zip ~/Downloads/oracle-stage/
cd ~/Downloads/oracle-stage && python -m http.server 8000 --bind 0.0.0.0
```
```powershell
$ip = (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway).IPv4Address.IPAddress | Select-Object -First 1
ssh -p 2211 root@127.0.0.1 "cd /scratch/software/stage && for f in oracle-gridhome-19.32.zip oracle-dbhome-19.32.zip; do curl -fSL -o `$f http://${ip}:8000/`$f || exit 1; done; ls -lh"
ssh -p 2211 root@127.0.0.1 "sha256sum /scratch/software/stage/oracle-*-19.32.zip"   # compare with sha256sum on Windows
```

Stop the server with Ctrl+C when the checksums match. The build guide's Phase 7 has the check for the
doc's one-off patch fixes inside the zips.

### Phase 8: RAC pods

```powershell
.\12-rac-pods.ps1                # create and check; -CheckOnly to recheck; -Delete to remove
```

It creates `ssh-key-secret`, the headless services (`racnode1-0`, `racnode2-0`, their `-vip` names and
`racnode-scan`) and both StatefulSets. Then it checks each pod: systemd, hostname, eth1 and eth2 at
.141/.142 with a ping to the other node, ASM devices `grid:asmadmin 660`, `/u01` writable,
`/mnt/.ssh` read-only, `/stage` holding the zips (node 1), and DNS for all five names.

### Phase 9: Grid Infrastructure

```powershell
.\13-grid-install.ps1            # 45-75 minutes; asks for the SYSASM password once; rerun to resume
.\13-grid-install.ps1 -Check     # cluster checks only
```

Long steps run detached inside the pods and log to `/u01/poc-logs/<step>.log`, so a dropped SSH
session doesn't stop the install. Rerun the script and it carries on where it was.

### Phase 10: RAC database

```powershell
.\14-db-install.ps1              # 45-90 minutes; asks for the SYS/SYSTEM/PDB admin password once
.\14-db-install.ps1 -Check       # database checks only
```

It runs the doc's `dbca` command with one change: `-totalMemory 3600` instead of `-memoryPercentage 30`.
The doc's option needs fix 34436514, which isn't in the 19.32 gold image. On the first run DBCA sized
SGA+PGA at 6,498 MB from the 22 GB worker instead of about 3,600 MB from the 12 GiB pod. The checks
report SGA+PGA, whether the SGA fits the pod's hugepages, datapatch status per container, and PDB
plug-in violations.

### Phase 11: client connections (inside and outside the cluster)

Inside the cluster: a client pod in its own namespace connects with the doc's SCAN name.

```powershell
Get-Content .\rac\dbclient.yaml -Raw | ssh -p 2210 root@127.0.0.1 "tr -d '\r' | kubectl apply -f - && kubectl -n rac-client wait --for=condition=Ready pod/dbclient --timeout=120s"
ssh -p 2210 root@127.0.0.1 "kubectl -n rac-client exec dbclient -- bash -c 'dnf -y -q install oracle-instantclient-release-23ai-el9 && dnf -y -q install oracle-instantclient-sqlplus && sqlplus -V'"
Get-Content .\rac\scan-test.sh -Raw | ssh -p 2210 root@127.0.0.1 "tr -d '\r' | kubectl -n rac-client exec -i dbclient -- bash -c 'cat > /root/scan-test.sh'"
ssh -t -p 2210 root@127.0.0.1 "kubectl -n rac-client exec -it dbclient -- bash /root/scan-test.sh"
```

Outside the cluster: the doc's procedure (listener `db-lsnr` on 30203,30204; `local_listener` set to
the VIP FQDNs; `rac/racnode-np-svc.yaml`), plus three NAT port forwards (30200, 30203, 30204 to
10.0.1.11) and two hosts-file lines mapping `racnode1-0-vip.rac.svc.cluster.local` and
`racnode2-0-vip.rac.svc.cluster.local` to 127.0.0.1 (Administrator PowerShell). Then:

```powershell
pip install oracledb
python .\scan_test.py
```

Both tests should show connections spread across ORCLCDB1 and ORCLCDB2. The build guide's Phase 11
has the full commands and the reason for each piece.

### Phase 12: survive pod deletion

Grid's root scripts write startup files outside `/u01` (`/etc/oracle`, `/etc/oratab`, `/etc/oraInst.loc`,
`/etc/init.d/init.ohasd` and `ohasd`, the `oracle-ohasd` systemd unit, `/usr/local/bin/oraenv`). Only
`/u01` is on the worker's disk, so a recreated pod would have the Grid home but no way to start Grid.

```powershell
.\10-rac-image-and-asm.ps1 -Rebuild -ImageOnly   # image whose setupContainerEnv.sh calls the /u01 hook; running pods untouched
.\15-pod-persistence.ps1                         # snapshot both pods into /u01/app/restart-state, then check
```

At every pod start, `rc.local` runs `setupContainerEnv.sh`, which runs `/u01/app/restart-state/onstart.sh`.
If the Grid startup service is missing (the pod was recreated), it runs the Oracle doc's "Complete Pod
Restart Configuration Tasks" in the background: restores the grid/oracle home directories, SSH host
keys, `oratab`, `oraInst.loc` and `oraenv` from the snapshot (the doc's note recommends backing these up
under `/u01`), then `tfa_setup`, `rootcrs.sh -updateosfiles` and `crsctl start crs -wait`. The log is
`/u01/app/restart-state/onstart.log`. Tested by deleting racnode2-0: back to `1/1` in about 4 minutes.

`snapshot.sh` refuses to save when required files are missing and keeps the previous snapshot as
`os-files.tgz.prev`. Rerun `15-pod-persistence.ps1` after changing Grid or DB configuration.

The doc's manual procedure (for comparison, or if `onstart.sh` isn't installed), as root in the pod:
`tfa_setup -silent -crshome /u01/app/19c/grid`, `rootcrs.sh -updateosfiles`, `crsctl start crs -wait`,
then SSH keys, `ssh-keyscan` on both pods and the `.bashrc` lines. It does not recreate `/etc/oratab`,
`/etc/oraInst.loc` or `/usr/local/bin/oraenv`; copy those from the other pod.

## Daily use

```powershell
# Stop (workers first)
foreach ($n in "worker1","worker2","controlplane") { & "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm $n acpipowerbutton; Start-Sleep 20 }
# Start (controlplane first), then check
foreach ($n in "controlplane","worker1","worker2") { & "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm $n --type headless; Start-Sleep 30 }
.\90-validate.ps1
```

- SSH into the nodes with `ssh -p 2210 root@127.0.0.1` (controlplane); use port 2211 for worker1 and
  2212 for worker2.
- Don't snapshot the workers. VirtualBox doesn't allow snapshots of VMs with shareable disks attached.
- Pods need a minute or two after startup before validation passes.

## Rebuild from scratch

```powershell
.\99-destroy-lab.ps1               # removes all VMs, disks and the NAT Network
.\99-destroy-lab.ps1 -KeepGolden   # keeps the sealed golden VM; the rebuild then starts at cloning
.\00-build-all.ps1
```

## Fixes built in from the first manual build

| Problem seen | Fix |
| --- | --- |
| PowerShell aborted on ssh's normal stderr messages | `ErrorActionPreference = Continue`, with exit codes checked explicitly |
| `startvm` refused right after a snapshot (session lock) | Start retries up to 6 times |
| Personalize stopped silently after deleting the network profile | Profile-cleanup function always returns success |
| SSH session dropped when the node changed IP, killing the script | Script runs detached (`setsid nohup`) and logs to `/root/personalize.log` |
| Checks ran while disks were still being formatted | Build waits for the script to finish and reboot before checking |
| `sdX` names don't follow VirtualBox port order; on worker2 `sdc` was an ASM disk | Data disks chosen by size; mounts by UUID; ASM by `/dev/disk/by-id` |
| `crictl` missing | `cri-tools` installed, with `/etc/crictl.yaml` pointing at CRI-O |
| kubeadm warned about a pause image mismatch | CRI-O `pause_image` set to the image kubeadm expects |
| Image copy to worker2 through Windows ran at about 0.1 MB/s | Copied straight from worker1 to worker2 over 10.0.1.x |
| Staging 9.6 GB of zips through the port forward was too slow | worker1 downloads them from a Python HTTP server on the PC (about 200 MB/s) |
| macvlan traffic dropped between workers | Private NICs set promiscuous in the guest (`accept-all-mac-addresses yes`) as well as VirtualBox Allow All |
| Pod requested IPs ignored | NAD has `"capabilities": {"ips": true}` |
| RAC pod (systemd as PID 1) exited about 1 s after start, no logs | SELinux boolean `container_manage_cgroup` on (OCNE sets it through `olcne-selinux`) |
| Test-pod ping "permission denied" | Test pods add `NET_RAW` (CRI-O drops it by default) |
| 6 vCPU workers on an 8-thread host | Worker vCPUs chosen from the host's thread count |
| Validator's `asm-pv-file` check passed on placeholder IDs | Check reads the real PV paths |
| Smoke test reported false failures (systemd state, `main.py`) | Error output ignored; `pgrep` pattern can't match itself |
| `unzip` missing on the nodes | Added to prep and the validator |
| Grid unzip step failed: `opatch lspatches` exit 135 | Check removed (home not registered yet) |
| `gridSetup.sh` INS-10105 on `netmaskList` | Passed on the command line, not in the response file |
| Resumable step helper never started a step | PID file instead of a self-matching `pgrep` |
| Config tools INS-43080 (CVU post-check only) | Treated as success with warnings |
| DBCA DBT-05801: setuid bits and root ownership lost in the Grid home | setuid check after `root.sh` (the gold images store no setuid bits, so 0 right after the unzip is expected), ownership set only on empty homes |
| Recreated RAC pod had no Grid startup files (only `/u01` persists) | Snapshot under `/u01`, restored by `onstart.sh`, which runs the doc's restart steps |
| Fresh snapshot overwrote a complete one | `snapshot.sh` checks required files and keeps the previous snapshot |
| cluvfy PRVH-1526 / PRVF-4009 although SSH works | Plain `ssh-keyscan` entries next to the doc's hashed ones |
| Grid home drift after the recursive chown (417 files, extjob) | Rolling `crsctl stop crs`, `rootcrs.sh -updateosfiles`, `crsctl start crs`; extjob root 4750; `cluvfy comp software` PASSED |
| Client pod `dnf` killed with exit 137 | Client pod memory limit 1.5 GiB |
| DBCA sized memory from the worker, not the pod (bug 34436514 not fixed in 19.32) | `-totalMemory 3600`; existing database resized with `alter system ... scope=spfile` |

The build guide's **Issues log** lists every issue with its cause, including the operator traps
(rerunning a step with its old `.rc` file, bash escaping in PowerShell, `.ps1` in Git Bash).

## Lab-only shortcuts

These are not for real systems:

- SSH ignores host keys for the `127.0.0.1` port forwards.
- firewalld is off.
- The root password is used for root SSH.
- VirtualBox keeps a copy of the install password in the golden VM's `Unattended-*` files.
