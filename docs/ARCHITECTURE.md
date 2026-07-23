# Architecture

## Goal

Keep one always-available Codex environment in Azure without leaving an administrative port open, while preserving many Git repositories independently of VM replacement and allowing occasional Mac filesystem access.

## Runtime and access

Codex runs on the VM as `azureadmin`. Cloud-init installs the pinned verified CLI and attempts `codex app-server daemon bootstrap --remote-control` with that user's `HOME` and `CODEX_HOME`; it never creates daemon state under `/root`. Before daemon bootstrap, the Ubuntu host installs the distribution `bubblewrap` package and loads the `bwrap-userns-restrict` AppArmor profile so Codex does not depend on the bundled sandbox fallback. ChatGPT authentication and pairing remain post-deploy user actions because their credentials and short-lived codes must not enter Terraform state or cloud-init.

Remote Control is the normal path after pairing. It uses the managed daemon and outbound connectivity, so neither the Codex app server nor an unauthenticated listener is exposed publicly. The official Codex manual describes `codex remote-control start` as starting the local daemon with Remote Control enabled and `codex remote-control pair` as producing a short-lived pairing code.

Codex's detached updater is not reboot-persistent, so cloud-init installs a systemd boot service that re-runs managed bootstrap as `azureadmin` and a one-minute timer that invokes the production health helper. The helper uses supported lifecycle commands first. It signals a stale updater only when the daemon's PID records, process start times, user, exact updater command, defunct child state, and parent relationship all match; it never deletes authentication, pairing, or daemon settings.

The VM retains a Standard public IP for outbound connectivity and emergency SSH, but the base network security group has no inbound allow rule. From the Mac, `scripts/remote-control-recover.sh` uses [Azure Run Command](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command) to verify and reconcile the exact checked-in health helper, installs it only when the VM copy differs, and invokes it through the VM agent without opening SSH. Repeated calls leave an already matching helper unchanged. If that control path is unavailable, `scripts/ssh-open.sh` temporarily creates only `AllowTemporarySsh` for the operator's current globally routable IPv4 `/32` on TCP/22, then reads back source, port, and access. `scripts/ssh-close.sh` removes that deterministic rule and keeps recovery state until Azure confirms it is absent. SSH itself allows only the generated Mac Ed25519 key, rejects passwords and root, and uses a host key captured through Azure Run Command.

This is restricted temporary access, not the paid Defender JIT product. Defender JIT adds server-enforced expiry and audit workflow but [requires Defender for Servers Plan 2](https://learn.microsoft.com/en-us/azure/defender-for-cloud/enable-just-in-time-access). Terraform can enable Defender pricing at subscription scope, so doing so implicitly is an unacceptable cost boundary for this repository. Azure Bastion is another valid design when removing the VM public IP is worth its managed resource and cost; [Bastion can connect to a VM private IP](https://learn.microsoft.com/en-us/azure/bastion/bastion-connect-vm-ssh-linux).

## Workspace storage decision

The live workspace is a 256 GiB Standard SSD managed disk attached at LUN 0 and formatted as ext4. Cloud-init locates it through Azure's predictable `/dev/disk/azure/data/by-lun/0` link, creates a partition and filesystem only when the disk is blank, and persists the mount at `/home/azureadmin/projects` by UUID. Microsoft recommends stable Azure device links and UUID-based `/etc/fstab` entries because Linux device names can change across boots. See [Azure Linux VM utilities](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/azure-virtual-machine-utilities) and [attach and mount a data disk](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/attach-disk-portal).

This is the best default when the VM is the primary Git and build machine:

- A managed disk is block storage presented to one VM, so ext4 provides native Linux permissions, links, file locking, and low-latency metadata behavior. [Azure managed disk types](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types) include Standard SSD as the cost-sensitive general-purpose SSD tier.
- Git, package managers, language servers, and builds create many small metadata operations. Azure Files is a network filesystem, and Microsoft notes that metadata-heavy workloads are sensitive to metadata latency and that SMB metadata caching is a performance consideration. See [Azure Files performance](https://learn.microsoft.com/en-us/azure/storage/files/understand-performance) and [SMB performance](https://learn.microsoft.com/en-us/azure/storage/files/smb-performance).
- The disk is independent of the VM resource, denies public disk access, has an Azure `CanNotDelete` lock and Terraform `prevent_destroy`, and is included in [Azure VM backup](https://learn.microsoft.com/en-us/azure/backup/selective-disk-backup-restore).

Azure Files would be preferable if simultaneous first-class SMB mounts from multiple machines were the primary requirement. It is not selected because the VM is the source of truth for many active Git repositories. Premium SSD Azure Files with suitable provisioning and metadata caching could reduce latency, but it adds cost and still makes the live repository a shared network filesystem.

## Mac access

`scripts/workspace-open.sh` uses SSHFS over the same temporary restricted SSH window. It exposes `/home/azureadmin/projects` at `~/Volumes/codex-on-vm` by default and accepts one absolute remote-path argument when the operator needs another VM directory such as `/home/azureadmin`. The mount does not make Azure storage credentials or TCP/445 part of the design. It is secondary access: use it for inspection and occasional local tools, keep heavy Git/build operations on the VM, and never mutate one working tree concurrently from both systems.

If high-performance Mac-native work becomes the main workflow, keep a separate Mac clone and synchronize through normal Git remotes. A managed disk cannot be attached as writable block storage to the Mac while it is attached to the VM.

## Persistence and failure boundaries

- Replacing the VM: the managed disk and its data survive, then Terraform reattaches it at LUN 0.
- Recreating all infrastructure: the disk destruction guard must be deliberately removed after a verified export; this prevents an ordinary destroy from silently erasing the repositories.
- Backup: the Recovery Services vault protects the VM with data-disk LUN 0 included and 30 daily recovery points. Configuration is not a restore test; operations still require a live restore drill.
- Existing Azure Files deployment: this code does not migrate it. Back up and verify the old share before applying a plan that removes it.
- Remote Control failure: systemd performs boot and periodic recovery; Azure Run Command is the first operator recovery path, and temporary `/32` SSH is the final fallback. The app-server itself is never opened as a public listener.
