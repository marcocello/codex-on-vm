# Remote-Control-First Managed Workspace

## Summary
Rebuild Codex on VM around a managed Remote Control daemon, a persistent managed disk for Git repositories, and temporary source-restricted SSH instead of permanently exposed SSH and Azure Files.

## Desired Behavior
- Terraform creates no permanent inbound SSH allow rule. The VM keeps a public address only so an authenticated operator can temporarily allow TCP/22 from the operator's current public IPv4 `/32` and so the VM has an outbound path.
- Repository helpers open and close one deterministic temporary SSH rule, verify the exact source address and port, record no secrets, and retain recovery state when cleanup cannot be verified.
- Codex is installed from the pinned verified package into `azureadmin`'s managed standalone path at `~/.codex/packages/standalone/current/codex`, and daemon bootstrap runs that executable as `azureadmin`, never as root. After the operator authenticates, the pinned CLI can enable Remote Control and issue a short-lived pairing code.
- Systemd re-runs managed daemon bootstrap after every VM boot and invokes a bounded health check every minute. The health check uses Codex lifecycle commands first and may terminate a stale updater parent only when its PID, process start time, user, command, defunct app-server child, and parent relationship all match the daemon's own records.
- `/home/azureadmin/projects` is an ext4 filesystem on a separately managed Standard SSD data disk. Provisioning formats only an empty unformatted disk, reuses an existing filesystem, mounts it by UUID, and gives `azureadmin` ownership.
- The managed disk remains a separate Terraform resource when the VM is replaced, denies public disk access, has an Azure delete lock and Terraform destruction guard, and is included in daily VM backup with 30-day retention.
- On macOS, `workspace-open.sh` mounts `/home/azureadmin/projects` by default and accepts one absolute remote-path argument, such as `/home/azureadmin`, when the operator needs a different VM directory. Opening the mount first opens temporary `/32` SSH access; closing it unmounts before removing SSH access.
- Terraform outputs and the README lead the operator through apply, temporary first access, ChatGPT device authentication, daemon enablement/pairing, verification, SSH closure, and optional on-demand SSHFS mounting.
- A repository helper recovers Remote Control through Azure Run Command without opening SSH. Temporary source-restricted SSH remains the final fallback when the Azure VM agent cannot perform recovery.

## Scope
- Replace Azure Files, SMB OAuth, storage-account keys, SMB firewall helpers, and mobile SSH-key provisioning in the production root.
- Preserve the verified Codex installer, pinned Ubuntu image, key-only SSH authentication, strict host-key verification, and unattended security updates. Mount the persistent workspace directly at `/home/azureadmin/projects`.
- Add an architecture note that records the access and storage decision with current official-source rationale.
- Add boot recovery, periodic health checking, and an Azure-control-plane recovery command without introducing another app-server owner.

## Non-Goals
- Enabling Microsoft Defender for Servers Plan 2 or Azure Bastion automatically.
- Migrating data from the existing Azure Files share to the managed disk.
- Keeping SSH or the SSHFS mount available after the temporary access rule is closed.
- Proving live Azure provisioning, real Remote Control enrollment, real FUSE mounting, backup completion, or restore behavior in this local run.
- Guaranteeing recovery while the VM is stopped, outbound connectivity is unavailable, authentication is invalid, or both the Azure VM agent and temporary SSH recovery path are unavailable.

## Scenarios
- A fresh apply leaves TCP/22 unreachable until the operator explicitly opens access from the current public IPv4 address.
- First activation runs under `azureadmin`: authenticate with ChatGPT, re-enable the provisioned daemon's Remote Control state, generate the pairing code, verify mobile access, then close SSH.
- After a VM reboot, systemd bootstraps the same managed standalone daemon as `azureadmin`; the timer restores an ordinarily stopped daemon without replacing or deleting pairing state.
- If a supported start/restart cannot clear the verified defunct-child state observed in production, recovery terminates only the matching stale updater parent and retries the managed Remote Control start.
- If Remote Control is unavailable while SSH is closed, the operator invokes the repository Azure Run Command helper before considering temporary `/32` SSH.
- Replacing only the VM reattaches and remounts the existing managed disk without formatting it.
- Running `workspace-open.sh` without an argument mounts the persistent projects directory; passing `/home/azureadmin` mounts the user home through the same local SSHFS and temporary-access lifecycle.
- A relative remote path or more than one path argument fails before temporary SSH is opened.
- A failed SSHFS mount removes the temporary NSG rule; if cleanup cannot be verified, state remains for the close helper to recover.
- If Remote Control stops working while SSH is closed, the operator uses the same temporary `/32` workflow or Azure Run Command to recover it.

## Constraints
- True Azure JIT is not silently enabled because it requires paid Defender for Servers Plan 2 at subscription scope. The README may describe it as an optional upgrade, but the default implementation is explicit temporary `/32` access.
- The VM exposes no app-server listener or unauthenticated public service. Remote Control uses the managed daemon and outbound relay.
- The Mac and VM must not run conflicting Git mutations in the same working tree at the same time.
- An operator-selected SSHFS remote path must be absolute and is limited to one positional argument; the helper does not interpret shell expressions or discover directories remotely.
- Existing Azure Files data must be backed up separately before applying this replacement; Terraform does not migrate it.
- Pairing codes, ChatGPT credentials, SSH private keys, and Azure credentials must not enter Terraform state, cloud-init, repository files, or proof artifacts.
- Automated recovery must never remove daemon settings, authentication, pairing, or workspace state, and it must refuse to signal an unverified or PID-reused process.

## Architecture Decision
- Selected: Standard SSD managed disk plus ext4 for the live Git workspace, with temporary SSHFS access from macOS. This prioritizes small-file metadata latency and native Linux filesystem behavior while preserving on-demand local mounting.
- Rejected: Standard Azure Files as the live Git working tree. Git and development tooling are metadata-heavy, while Azure Files performance remains network- and metadata-latency sensitive; SSD Azure Files with metadata caching would improve that path but adds cost and still shares one network filesystem between two active clients.
- Rejected as the default access product: Defender JIT and Bastion. Both are valid upgrades, but Defender JIT requires paid Plan 2 across the subscription's VM resource type and Bastion adds a managed access resource and cost.
- Rejected: supervising a second foreground `codex remote-control` process. Recovery keeps the standalone managed daemon as the single app-server owner and uses its lifecycle commands.

## Implementation Routing
- Required skills: coding-feature-execute, coding-proof-author, coding-research, openai-docs
