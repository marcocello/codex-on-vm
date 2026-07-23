# Proof Plan

## Definition Of Done
- The mocked Terraform plan has no permanent inbound SSH rule and creates a private-access-only managed disk attached at LUN 0.
- Rendered cloud-init publishes the verified Codex package at `azureadmin`'s daemon-required managed standalone path, installs the Linux sandbox prerequisites, loads the Ubuntu 24.04 `bwrap` AppArmor profile, safely prepares the data disk, mounts `/home/azureadmin/projects` by filesystem UUID, and bootstraps the daemon as that user.
- Rendered cloud-init installs a boot-time managed-daemon bootstrap service and a one-minute health timer. The production health script handles healthy, stopped, and precisely verified stale-updater/defunct-child states while refusing to signal mismatched processes.
- The backup plan includes the VM data disk, and the managed disk has a delete lock.
- The real temporary-access scripts create only an IPv4 `/32` TCP/22 rule, verify its exact identity and access values, and remove that same rule on close.
- The real macOS workspace scripts cross the SSHFS subprocess boundary, use the Terraform projects path by default, accept one absolute remote-path override, reject invalid input before opening SSH, read back the mounted state, and remove both the mount and temporary NSG rule on close or failed open.
- The real Azure recovery helper invokes Run Command for the intended VM and admin user without creating an NSG rule or opening SSH.
- README and architecture documentation describe the no-public-SSH default, first pairing workflow, managed-disk rationale, migration warning, recovery path, and optional paid JIT upgrade.

## Primary Proof
Type: cli-subprocess

Boundary:
- Producer: Terraform configuration, systemd timer activation, and operator invocation of repository recovery, access, and workspace helpers.
- Activation path: the verified-installer proof executes the packaged `current/codex`, `terraform test` plans the production root, then the proof invokes the production daemon-health, Azure recovery, temporary-access, and workspace scripts as subprocesses.
- Consumer: AzureRM configuration, rendered cloud-init/systemd units, managed Codex lifecycle commands, process-record validation, Azure Run Command, temporary SSH lifecycle, and SSHFS workspace lifecycle.
- Durable state: Mocked Terraform plan, daemon-format PID records, process/signal call log, temporary access JSON, fake NSG rule state, and fake mount state.
- Read-back: Terraform assertions, rendered cloud-init assertions, managed-daemon JSON status, exact process/signal calls, fake Azure Run Command/NSG queries, JSON state inspection, mount-state queries, and call-log ordering.
- Unsafe edge: Azure control-plane calls, Codex daemon processes, process signals, public-IP discovery, SSHFS/FUSE, Remote Control enrollment, and live backup are replaced only at their outer command/provider boundaries.

Command:
```bash
scripts/proof_run_capture --feature-dir docs/features/remote-control-managed-workspace --timeout-seconds 45 --note "Verify managed daemon boot recovery, safe stale-process repair, Azure Run Command, managed disk, and temporary access"
```

Expected evidence:
- Terraform test reports the managed-workspace plan passed, and a source guard confirms the production root declares no inline or standalone NSG rule.
- A source guard confirms the workspace managed disk enables Terraform `prevent_destroy` in addition to its Azure delete lock.
- Cloud-init includes safe empty-disk detection, UUID fstab mounting, and a user-owned daemon bootstrap.
- Cloud-init installs and verifies `~/.codex/packages/standalone/current/codex` as `azureadmin` and uses that exact executable for daemon bootstrap.
- Cloud-init installs `bubblewrap`, `apparmor-profiles`, and `apparmor-utils`, verifies `bwrap` on `PATH`, and loads `bwrap-userns-restrict` before daemon bootstrap.
- Cloud-init installs and enables the boot bootstrap service and health timer after the initial managed daemon bootstrap.
- A healthy-daemon scenario invokes the idempotent start path and never restarts or signals a process.
- A stopped-daemon scenario starts the managed daemon and verifies the daemon's JSON status and managed executable path.
- A stale-process scenario proves the order `start -> restart -> TERM -> start -> JSON readiness`, and signals only an updater whose daemon PID records match its user, start time, exact command, defunct child, and parent relationship.
- Seven independent mismatch scenarios falsify updater user, updater start time, updater command, app-server user, app-server start time, zombie state, and parent relationship; every scenario exits non-zero without sending a signal.
- Authentication, pairing, and daemon settings sentinels remain unchanged across every recovery scenario.
- Azure recovery crosses the production helper boundary, invokes `az vm run-command invoke` for the Terraform VM, runs recovery as `azureadmin`, and does not create an SSH rule.
- Temporary access passes an exact inbound `8.8.8.8/32` TCP/22 create request to the fake Azure boundary, whose persisted request drives identity-aware production read-back and deletion; wrong-target show/delete requests fail without removing the rule.
- Workspace open refuses to take over or close a separately opened temporary SSH session.
- Workspace open without an argument calls SSHFS for `codex-on-vm:/home/azureadmin/projects`; an explicit `/home/azureadmin` argument reaches SSHFS unchanged.
- Relative paths and extra positional arguments fail before an NSG create call, mount state, or access state exists.
- Workspace close unmounts before deleting the NSG rule.
- Injected SSHFS failure leaves neither a fake mount nor a temporary NSG rule.

## Claimed Behavior Coverage
| FEATURE claim | Real production entrypoint proof drives | Fake boundary used | Read-back |
| --- | --- | --- | --- |
| No permanent SSH ingress | Production Terraform root plus source guard | Azure providers | No inline or standalone NSG rule declaration |
| Persistent Git workspace uses managed disk | Production Terraform root and rendered cloud-init | Azure providers | Disk SKU/access, LUN attachment, ext4/UUID mount commands |
| Daemon belongs to `azureadmin` | Rendered production cloud-init | Azure provider | `runuser`/HOME ownership and exact bootstrap command |
| Daemon uses its managed standalone package | Rendered production cloud-init plus production verified installer subprocess | Azure provider and remote bytes | Per-user `current/codex` path, version execution, and absence of `/opt/codex` |
| Daemon has the Linux sandbox prerequisites | Production Terraform root and rendered cloud-init | Azure provider | Distribution `bubblewrap` packages, `bwrap` readiness check, and Ubuntu AppArmor profile load |
| Daemon returns after reboot or ordinary exit | Rendered production systemd units and production health script subprocess | Azure provider, Codex CLI, process table | Enabled boot/timer configuration plus managed-daemon JSON readiness |
| Stale daemon recovery signals only the recorded owner | Production health script subprocess with daemon-format PID records | Codex CLI, process table, signal | Supported lifecycle attempts precede one verified parent signal; mismatched records produce no signal |
| Recovery works without opening SSH | Production `remote-control-recover.sh` subprocess | Fake Azure CLI | Exact VM Run Command argv and absence of NSG rule creation |
| Backup and delete protection cover workspace | Production Terraform root plan plus source guard | Azure providers | VM backup LUN, management-lock assertions, and Terraform destruction guard |
| Temporary SSH is exact and recoverable | Production `ssh-open.sh` and `ssh-close.sh` subprocesses | Fake Azure CLI and public-IP endpoint | Rule/state query and deletion read-back |
| Mac mount shares the selected VM directory only during access | Production `workspace-open.sh` default, override, invalid-input, and close subprocesses | Fake SSHFS and diskutil | Exact SSHFS argv, absent external state for invalid input, mount state, and unmount-before-rule-delete log |

## Fake Boundary Ledger
- Fake: AzureRM/External/Local provider operations, Azure CLI, public-IP HTTP response, Codex CLI responses, process-table reads and signals, SSHFS, macOS mount read-back, and diskutil. The Azure CLI fake persists the actual NSG create arguments, derives subsequent show responses from that state, and rejects show/delete requests whose resource-group, NSG, or rule identity differs.
- Allowed because: This local proof must not create billable resources, expose a real port, authenticate ChatGPT, mount kernel extensions, or mutate a real filesystem.
- Not faked: Terraform evaluation and cloud-init rendering; the production daemon-health, Azure recovery, access, and mount scripts; their branching, argument construction, PID-record validation, state transitions, cleanup ordering, error behavior, and read-back logic.

## Proof Scope
Proves:
- The local configuration defaults to no inbound SSH, plans the managed-disk/backup/daemon ownership, sandbox prerequisite, reboot bootstrap, and timer contract, and drives daemon recovery, Azure Run Command, temporary-access, and mount lifecycles through production script entrypoints.

Does not prove:
- Live Azure resource availability or replacement behavior, real NSG propagation timing, VM boot/device discovery, systemd execution on Ubuntu, actual `bwrap` execution under the Azure Ubuntu kernel/AppArmor policy, a real zombie process, Azure VM agent availability, paired-device reconnection, disk persistence, ChatGPT authentication/enrollment, phone discovery, real SSHFS/FUSE behavior, backup completion, restore, or Azure Files data migration.

False-green risks:
- Provider mocks can accept a field combination that Azure rejects at apply time.
- Rendered cloud-init can contain the correct packages and AppArmor setup while a future Ubuntu package or kernel change still prevents `bwrap` from creating a namespace.
- Rendered systemd units can be valid in source while a live boot ordering, VM-agent, authentication, or outbound-network failure still prevents reconnection.
- Fake process responses cannot reproduce every PID namespace or process-state race; the recovery script therefore refuses ambiguous records instead of broadening its kill behavior.
- Fake command responses cannot reproduce every Azure CLI or macOS FUSE failure mode.
- The user could leave a real temporary rule open if the Mac loses power before cleanup; Azure Defender JIT is required for server-enforced expiry.

Evidence strength:
- deterministic configuration and subprocess lifecycle proof with live Azure, Remote Control, and FUSE gaps

## Secondary Guards
- `terraform fmt -check -recursive`
- `terraform validate`
- `bash -n` for every production and proof shell script
- `git diff --check`
- Markdown link/path review for the README and architecture note

## Environment And Data
- Terraform 1.14+, initialized provider cache, Bash, Python 3, `jq`, and standard command stubs created under a temporary proof directory.
- No Azure credentials, ChatGPT credentials, SSH private-key bytes, or live provider state are required.

## Anti-Gaming Review
- Fake pass risk: leave the original wildcard TCP/22 rule while adding an open/close helper. Proof catch: the Terraform plan requires no configured NSG security rule.
- Fake pass risk: call a disk resource a workspace but keep cloud-init on Azure Files, the OS disk, or the old `/workspace` path. Proof catch: the plan and rendered cloud-init require the managed LUN, ext4, UUID fstab entry, exact `/home/azureadmin/projects` output, and SSHFS argv read-back.
- Fake pass risk: bootstrap the daemon as root. Proof catch: rendered cloud-init must invoke the exact command through `runuser` with the admin home and must not use `/root/.codex`.
- Fake pass risk: rely on Codex's bundled `bwrap` fallback while omitting the host sandbox prerequisites. Proof catch: rendered cloud-init must install the distribution packages, verify `bwrap`, and load the Ubuntu 24.04 AppArmor profile.
- Fake pass risk: write systemd unit files but never enable them. Proof catch: rendered cloud-init must reload systemd, enable the reboot service and timer, and start the timer after initial bootstrap.
- Fake pass risk: recover any timeout by broadly killing Codex processes. Proof catch: the stale scenario requires supported lifecycle calls before signaling and exact daemon PID record, process start time, user, command, zombie state, and parent relationship; each predicate is independently falsified and must send no signal.
- Fake pass risk: call the SSH helper from an apparent Azure recovery command. Proof catch: the production recovery helper must cross `az vm run-command invoke` and the call log must contain no NSG create.
- Fake pass risk: manufacture a safe NSG read-back independently of unsafe production create arguments. Proof catch: the Azure fake persists every create argument, drives show responses from that state, and the proof requires the complete expected inbound TCP/22 request.
- Fake pass risk: remove the access-state file or wrong Azure rule while leaving temporary ingress open. Proof catch: identity-aware show/delete operations preserve state on any target mismatch, and close verifies the intended provider rule is absent before state removal.
- Fake pass risk: accept a remote-path argument but ignore it or validate it only after opening SSH. Proof catch: the fake executable records exact default and override argv, while invalid relative and extra arguments must leave the NSG, access, mount, and call state untouched.
- Broken implementation that would still pass: Azure could change provider/runtime behavior after the pinned local versions; a reviewed live plan/apply and runtime receipt remain necessary.

## Proof Repair History

- 2026-07-22 user expansion: `workspace-open.sh` must optionally mount the VM user folder instead of always selecting the projects mount. The revised proof drives the production script with no argument, invalid input, and `/home/azureadmin`, then reads exact SSHFS argv and external state so an ignored or late-validated override fails.
- 2026-07-22 user correction: the persistent workspace must mount directly at `/home/azureadmin/projects`, not `/workspace`. The revised proof requires the exact Terraform output and rendered cloud-init path and drives the real SSHFS helper with that output; this changes the mount location without reintroducing Azure Files.
- 2026-07-20 evaluator correction: the Azure fake removed rule state for any delete and answered show requests without matching resource-group, NSG, or rule identity. The corrected boundary rejects wrong-target show/delete calls and leaves the intended rule present for recovery.
- Red evidence: captured attempt `proof/runs/20260720T201928314810Z` changes the production close helper to delete a different rule name; identity-aware Azure deletion rejects it and the proof fails with the temporary rule still present.
- 2026-07-20 evaluator correction: the Azure fake previously returned hard-coded safe NSG values after any create request, so wildcard, UDP, or outbound production arguments could pass. The corrected fake persists the actual create arguments, uses them for read-back, and requires the complete inbound `/32` TCP/22 request.
- Red evidence: captured attempt `proof/runs/20260720T201257859809Z` changes the production temporary rule from TCP to UDP; the persisted Azure create request exposes the mismatch and the proof fails.
- 2026-07-20 evaluator correction: the first recovery proof falsified only the updater command, so a script that ignored updater/app-server user, start-time, zombie-state, or parent predicates—or signaled before supported lifecycle recovery—could pass. The accepted strengthened proof independently falsifies all seven predicates and asserts the full supported-recovery-before-signal ordering.
- Red evidence: captured attempt `proof/runs/20260720T200620492957Z` removes updater-user validation from the production recovery script; the strengthened proof fails because that mismatch reaches the signal path.
- 2026-07-20 recovery expansion: upstream Codex documents the detached updater as not reboot-persistent, and the production incident showed that supported restart could time out on a defunct child. The accepted proof adds reboot bootstrap, a one-minute health path, safe exact stale-parent recovery, an Azure Run Command helper, and a negative mismatched-PID scenario. This expands behavior rather than weakening the existing daemon, storage, or access proof.
- Red evidence: captured attempt `proof/runs/20260720T195133569543Z` fails the new Terraform assertions because the pre-change cloud-init has no reboot bootstrap/health timer and the connection output has no VM name for Azure Run Command.
- 2026-07-20 runtime failure: `codex remote-control start` could not create `app-server-control.sock`; the only daemon stderr entry reported that `bubblewrap` was absent. After `bubblewrap` and the Ubuntu AppArmor profile were installed, the original July 17 updater still held a defunct app-server child and could not restart it. Terminating that verified stale updater allowed the supported Remote Control start to create the socket and report matching CLI/app-server version `0.144.6`.
- Root cause: cloud-init omitted the documented Linux sandbox prerequisites before its first daemon bootstrap. The previous proof validated daemon ownership and executable location but could pass while the host lacked `bwrap` and its Ubuntu 24.04 AppArmor profile.
- Strengthened proof: rendered cloud-init must install `bubblewrap`, `apparmor-profiles`, and `apparmor-utils`, verify `bwrap` on `PATH`, copy the distribution `bwrap-userns-restrict` profile, load that profile, and prove both operations precede daemon bootstrap. Live read-back confirmed the distribution `bwrap` namespace smoke test, loaded AppArmor profiles, a fresh control socket, and a running managed daemon.
- Evaluator correction: the first sandbox assertion checked only token presence, so a configuration that omitted the profile copy or loaded the profile after bootstrap could pass. The corrected Terraform assertion matches the copy, load, and bootstrap sequence in the rendered cloud-init.
- Red evidence: captured attempt `proof/runs/20260720T165128980789Z` removes the profile-copy operation and fails the corrected sandbox-prerequisite assertion. Earlier attempts `proof/runs/20260720T164102220324Z` and `proof/runs/20260720T164151983098Z` are retained but are not the focused red because their Terraform run also reports the fixture's intentional artifact SHA mismatch.
- 2026-07-17 pre-commit evaluation found that `storage.tf` set `prevent_destroy = false` even though the feature and architecture require a Terraform destruction guard. The previous proof checked only the Azure management lock, so it could pass while a normal Terraform destroy remained able to remove the disk after deleting the lock. The proof now requires the production managed-disk source to enable `prevent_destroy`; this fails against the pre-repair configuration without changing feature scope.
- 2026-07-17 runtime failure: `codex remote-control start` reported that the managed standalone install was missing from `/home/azureadmin/.codex/packages/standalone/current/codex`.
- Root cause: the verified package layout was correct, but cloud-init installed it under `/opt/codex`; the previous proof checked daemon ownership and bootstrap invocation without proving that the daemon's required per-user executable existed.
- Strengthened proof: rendered cloud-init must publish and verify `azureadmin`'s managed standalone executable, must not use `/opt/codex`, and the installer proof must execute `packages/standalone/current/codex`. This adds the missed runtime invariant without reducing feature scope.
- Red evidence: captured run `proof/runs/20260717T071022Z` fails the new Terraform assertion against the pre-repair `/opt/codex` implementation.

## Manual Gaps
- A reviewed `terraform plan` and explicitly approved live apply are required before claiming the Azure deployment works.
- After apply, verify `cloud-init status --wait`, `command -v bwrap`, the loaded `bwrap` AppArmor profile, systemd unit/timer state, a VM reboot, daemon version, paired-device reconnection, Azure Run Command recovery, `findmnt /home/azureadmin/projects`, disk UUID/attachment, temporary NSG closure, real SSHFS mount/unmount, backup protection, and restore readiness.
