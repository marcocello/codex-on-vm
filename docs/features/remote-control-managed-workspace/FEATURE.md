# Remote-Control-First Managed Workspace

## Summary
Rebuild Codex on VM around a managed Remote Control daemon, a persistent managed disk for Git repositories, and temporary source-restricted SSH instead of permanently exposed SSH and Azure Files.

## Desired Behavior
- Terraform creates no permanent inbound SSH allow rule. The VM keeps a public address only so an authenticated operator can temporarily allow TCP/22 from the operator's current public IPv4 `/32` and so the VM has an outbound path.
- Repository helpers open and close one deterministic temporary SSH rule, verify the exact source address and port, record no secrets, and retain recovery state when cleanup cannot be verified.
- During that temporary SSH window, the daemon permits client-originated TCP forwarding for VS Code Remote-SSH while continuing to reject remote forwarding, gateway exposure, and network-device tunnels.
- Terraform creates and connects Azure infrastructure without running guest preparation through custom data, cloud-init, a Terraform-managed VM Run Command, or a remote-exec provisioner. After a manual `terraform apply`, the operator runs `scripts/codex-vm.sh setup`; the console dispatches to its embedded machine-preparation helper, which reads Terraform outputs and launches the checked-in VM preparation payload through Azure Run Command without opening SSH.
- The local preparation entrypoint extracts every VM payload from `scripts/codex-vm.sh`, waits for the intended VM agent, verifies the active Azure subscription and every payload checksum, runs preparation as the Azure Run Command root context, reads back an explicit readiness marker and SSH host key, and writes the strict Mac SSH configuration only after remote preparation succeeds. Repeated runs are idempotent and preserve persistent Codex and workspace state.
- The remotely invoked production provisioner installs host prerequisites, safely prepares and mounts the managed disk, installs the pinned verified Codex package into a persistent home under `/home/azureadmin/projects`, exposes that home through `~/.codex`, publishes the CLI from a persistent bin directory, hardens SSH, and installs systemd recovery as `azureadmin`, never as root. An existing persistent `dot-codex` checkout takes precedence over the initial `.codex` directory so VM replacement reuses configuration, authentication, sessions, skills, packages, and daemon state.
- Systemd is the only VM-initiated execution boundary after preparation. It re-runs managed daemon bootstrap after every VM boot and invokes a bounded health check every minute. Both oneshot units explicitly preserve the detached Codex-managed daemon after their launcher exits. The health check separately verifies local daemon liveness and the machine-readable Remote Control connection state, throttles restarts during sustained relay failures, uses Codex lifecycle commands first, and may terminate a stale updater parent only when its PID, process start time, user, command, defunct app-server child, and parent relationship all match the daemon's own records.
- `/home/azureadmin/projects` is an ext4 filesystem on a separately managed Standard SSD data disk. The locally launched provisioner formats only an empty unformatted disk, reuses an existing filesystem, mounts it by UUID, and gives `azureadmin` ownership.
- The managed disk remains a separate Terraform resource when the VM is replaced, denies public disk access, has an Azure delete lock and Terraform destruction guard, and is included in daily VM backup with 30-day retention.
- On macOS, `scripts/codex-vm.sh workspace-open` mounts `/home/azureadmin/projects` by default and accepts one absolute remote-path argument, such as `/home/azureadmin`, when the operator needs a different VM directory. Opening the mount first opens temporary `/32` SSH access; closing it unmounts before removing SSH access.
- Terraform outputs and the README lead the operator through apply, local machine preparation, locally launched ChatGPT device authentication, a separate pairing action, verification, and optional on-demand SSHFS mounting. The operator is never instructed to enter the VM and launch a setup script manually.
- The console's embedded macOS recovery helper recovers Remote Control through Azure Run Command without opening SSH. Each invocation verifies and reconciles the checked-in VM recovery helper to `/usr/local/sbin/ensure-codex-remote-control`, installs it only when its bytes differ, and then invokes it as `azureadmin`; repeated invocations make no unnecessary installation change. Temporary source-restricted SSH remains the final fallback when the Azure VM agent cannot perform recovery.

## Scope
- Replace Azure Files, SMB OAuth, storage-account keys, SMB firewall helpers, and mobile SSH-key provisioning in the production root.
- Preserve the verified Codex installer, pinned Ubuntu image, key-only SSH authentication, strict host-key verification, and unattended security updates. Mount the persistent workspace directly at `/home/azureadmin/projects`.
- Add an architecture note that records the access and storage decision with current official-source rationale.
- Add boot recovery, periodic health checking, and an Azure-control-plane recovery command without introducing another app-server owner.
- Move machine preparation and SSH host-key capture out of Terraform/cloud-init into local operator entrypoints while keeping remote execution behind the Azure control plane until temporary SSH is explicitly needed.

## Non-Goals
- Enabling Microsoft Defender for Servers Plan 2 or Azure Bastion automatically.
- Migrating data from the existing Azure Files share to the managed disk.
- Keeping SSH or the SSHFS mount available after the temporary access rule is closed.
- Proving live Azure provisioning, real Remote Control enrollment, real FUSE mounting, backup completion, or restore behavior in this local run.
- Guaranteeing recovery while the VM is stopped, outbound connectivity is unavailable, authentication is invalid, or both the Azure VM agent and temporary SSH recovery path are unavailable.

## Scenarios
- A fresh apply leaves TCP/22 unreachable until the operator explicitly opens access from the current public IPv4 address.
- A fresh apply creates no guest configuration side effect. `scripts/codex-vm.sh setup` then prepares the intended VM through Azure Run Command, verifies the persistent mount and Codex installation, and creates the local SSH files without opening TCP/22.
- With temporary SSH access open, VS Code Remote-SSH can establish its client-side tunnel to the VM-hosted VS Code Server without enabling SSH remote forwarding.
- First activation is launched from macOS through separate sign-in and pairing actions backed by one local account helper. Sign-in opens restricted temporary SSH and authenticates as `azureadmin` without starting or pairing Remote Control. Pairing requires an existing login, enables Remote Control, prints the short-lived pairing code, and closes SSH on success, failure, or interruption.
- After a VM reboot, systemd bootstraps the same managed standalone daemon as `azureadmin`; the timer restores an ordinarily stopped daemon without replacing or deleting pairing state.
- On an authenticated machine, `scripts/codex-vm.sh setup` activates both installed oneshot units after systemd reload and tolerates a bounded transient relay transition between bootstrap and the connected health result; after either service exits successfully, the detached updater, app-server process, control socket, and daemon version read-back remain available.
- A locally healthy daemon is considered remotely ready only when `remote-control start --json` reports `status=connected`, `timedOut=false`, and a non-empty environment identity. A transient relay failure records a consecutive failure and leaves the local daemon running; only the fifth consecutive failure permits one restart, and further restarts use bounded exponential backoff until a connected result resets recovery state.
- A locally stopped daemon is repaired immediately without waiting for the relay-failure threshold. If the restarted daemon remains locally healthy but remotely degraded, the helper reports failure instead of presenting a systemd false green.
- If a supported start/restart cannot clear the verified defunct-child state observed in production, recovery terminates only the matching stale updater parent and retries the managed Remote Control start.
- If Codex or Remote Control is unavailable while SSH is closed, the operator reruns `scripts/codex-vm.sh setup` from macOS. The delegated preparation reconciles the installation and recovery helper idempotently before the operator considers temporary `/32` SSH.
- Replacing only the VM reattaches and remounts the existing managed disk without formatting it.
- Replacing only the VM requires rerunning `scripts/codex-vm.sh setup`; that command recreates the `~/.codex` compatibility symlink and `/usr/local/bin/codex` publication after the projects disk is mounted, then reuses the persistent Codex home without deleting unrelated state.
- Running `scripts/codex-vm.sh workspace-open` without an argument mounts the persistent projects directory; passing `/home/azureadmin` mounts the user home through the same local SSHFS and temporary-access lifecycle.
- A relative remote path or more than one path argument fails before temporary SSH is opened.
- A failed SSHFS mount removes the temporary NSG rule; if cleanup cannot be verified, state remains for the close helper to recover.
- If Remote Control stops working while SSH is closed, the operator uses the same temporary `/32` workflow or Azure Run Command to recover it.

## Constraints
- True Azure JIT is not silently enabled because it requires paid Defender for Servers Plan 2 at subscription scope. The README may describe it as an optional upgrade, but the default implementation is explicit temporary `/32` access.
- The VM exposes no app-server listener or unauthenticated public service. Remote Control uses the managed daemon and outbound relay.
- SSH must use `AllowTcpForwarding local`; unrestricted `yes`/`all`, remote-only forwarding, gateway ports, and TUN/TAP forwarding remain disabled.
- The Mac and VM must not run conflicting Git mutations in the same working tree at the same time.
- An operator-selected SSHFS remote path must be absolute and is limited to one positional argument; the helper does not interpret shell expressions or discover directories remotely.
- Existing Azure Files data must be backed up separately before applying this replacement; Terraform does not migrate it.
- The locally launched provisioner must refuse an unexpected real `~/.codex` directory instead of overwriting it. Migration from an older OS-disk Codex home is an explicit pre-replacement operator step.
- Pairing codes, ChatGPT credentials, SSH private keys, and Azure credentials must not enter Terraform state, cloud-init, repository files, or proof artifacts.
- Automated recovery must never remove daemon settings, authentication, pairing, or workspace state, and it must refuse to signal an unverified or PID-reused process.
- The bootstrap and health units must use `KillMode=process`; systemd owns only each short-lived launcher while the Codex standalone daemon remains the single app-server owner.
- Both units must use systemd's supported `ConditionFileIsExecutable` directive for the managed Codex binary; an ignored or misspelled executable condition is not an acceptable fail-closed guard.
- Automated readiness must not treat `connecting`, a timed-out result, a missing environment identity, command exit alone, local PID existence alone, or `systemd` unit success as a connected Remote Control result.
- The Mac recovery entrypoint must install only the exact VM helper embedded in `scripts/codex-vm.sh`, verify its content before installation, and avoid rewriting an already matching target.
- Local preparation must fail closed when Terraform outputs are unsafe, Azure CLI targets another subscription, the VM agent is unavailable, a payload checksum differs, remote preparation fails, or readiness cannot be read back. It must not create local SSH trust files before successful read-back.

## Architecture Decision
- Selected: Standard SSD managed disk plus ext4 for the live Git workspace, with temporary SSHFS access from macOS. This prioritizes small-file metadata latency and native Linux filesystem behavior while preserving on-demand local mounting.
- Selected for Codex persistence: keep the physical Codex home and CLI publication on the same managed disk, while retaining `~/.codex` as the stable user-facing path. Rejected: installing under the ephemeral VM home and relying on VM-local state to survive replacement.
- Selected for deployment ownership: Terraform creates infrastructure, then a local macOS command launches all one-time guest preparation through Azure Run Command and performs provider/read-back verification. Rejected: full cloud-init provisioning, Terraform-managed guest commands, and instructions that require the operator to enter the VM and launch setup scripts.
- Selected runtime exception: locally installed systemd units may start the managed Codex binary and health helper after boot. Rejected: requiring the Mac to remain online for reboot recovery.
- Rejected: Standard Azure Files as the live Git working tree. Git and development tooling are metadata-heavy, while Azure Files performance remains network- and metadata-latency sensitive; SSD Azure Files with metadata caching would improve that path but adds cost and still shares one network filesystem between two active clients.
- Rejected as the default access product: Defender JIT and Bastion. Both are valid upgrades, but Defender JIT requires paid Plan 2 across the subscription's VM resource type and Bastion adds a managed access resource and cost.
- Selected for temporary SSH: local TCP forwarding, which supports VS Code Remote-SSH without permitting server-listening remote forwards. Rejected: disabling all TCP forwarding because it breaks Remote-SSH, and unrestricted forwarding because the additional capability is unnecessary.
- Selected for daemon ownership: keep the standalone Codex-managed daemon as the single app-server owner and make systemd an explicit `KillMode=process` launcher/probe boundary. Rejected: supervising a second foreground `codex remote-control` process or letting the default control-group teardown kill the managed daemon when a oneshot launcher exits.

## Implementation Routing
- Required skills: coding-feature-execute, coding-proof-author, coding-research, openai-docs
