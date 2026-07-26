# Proof Plan

## Definition Of Done
- The mocked Terraform plan creates the VM, protected managed disk, backup, and private-by-default network without `custom_data`, a Terraform-managed VM Run Command, a remote-exec provisioner, or a permanent inbound SSH rule.
- Terraform exposes the non-secret VM, disk, Codex package, and local SSH-path values required by repository-owned local entrypoints.
- The real machine-preparation implementation and VM payload bundle extracted from `scripts/codex-vm.sh` read Terraform output, verify the active subscription, wait for the intended VM agent, and send the exact provisioner and supporting helpers through Azure Run Command without opening SSH.
- The Azure boundary executes that transmitted payload in an isolated VM fixture. Read-back proves checksummed helper reconciliation, package installation, ext4 UUID persistence, the selected persistent Codex home, CLI publication, SSH hardening, systemd mount dependencies, readiness marking, and SSH host-key return.
- Fresh-host SSH validation requires the provisioner to create `/run/sshd` before `sshd -t`, then reload an active `ssh.service`, preserve an active `ssh.socket`, or enable/start SSH when neither is active; a missing readiness marker must surface the bounded Azure Run Command diagnostic instead of hiding the guest failure.
- Local SSH known-hosts and host configuration files are written only after the remote readiness marker and host key are returned. A second preparation run preserves persistent authentication state and converges without a second disk format.
- The real local account helper owns temporary SSH cleanup. Its sign-in mode launches login as the VM admin user without starting or pairing Remote Control; its pairing mode requires an existing login before Remote Control start and pairing. No documented workflow asks the operator to enter the VM and launch setup commands.
- On an authenticated machine, `scripts/codex-vm.sh setup` activates both installed oneshot units after systemd reload and retries a bounded transient relay transition between bootstrap and the connected health result. Retained live read-back proves both units completed successfully and preserve the same Codex-managed detached daemon after their launcher exits. Recovery distinguishes a connected Remote Control result from a merely running local daemon, repairs a locally stopped daemon immediately, delays relay-only restarts until five consecutive failures, and applies bounded exponential backoff through the configured cap without changing authentication, pairing, settings, or workspace state.
- Existing temporary access and SSHFS workspace lifecycles retain their exact safety behavior.

## Primary Proof
Type: CLI subprocess, provider boundary, and live systemd read-back

Boundary:
- Producer: Terraform output plus operator invocation of repository-local preparation, pairing, recovery, access, and workspace entrypoints.
- Activation: the local proof invokes the production scripts through a fake Azure CLI that executes the actual transmitted preparation payload in an isolated VM filesystem. The final remediation attempt runs after activation exclusively through `scripts/codex-vm.sh setup` and enables a read-only live Azure Run Command scenario.
- Consumer: the production VM provisioner, verified installer, persistent-home selector, systemd/SSH configuration writer, local SSH configuration writer, daemon recovery helper, access/workspace scripts, and the deployed VM's real systemd manager and Codex daemon.
- Durable state: Terraform plan, isolated VM filesystem, ext4/fstab model, persistent Codex home, installed package layout, systemd and SSH files, preparation marker, local SSH files, process records, temporary NSG rule state, mount state, and the deployed units/daemon state.
- Read-back: Terraform assertions, exact Azure CLI calls, payload execution, checksummed installed bytes, filesystem contents and symlinks, preserved authentication sentinel, command ordering, local SSH file contents, daemon JSON status, provider rule queries, mount queries, real unit properties/results, timer state, PID file, Unix socket, daemon version, and connected Remote Control JSON before a ten-second survival interval.
- Unsafe edge: provisioning, block-device formatting, package changes, sign-in, pairing, public-IP discovery, process signals, and SSHFS/FUSE remain replaced at their outer boundaries. The live scenario performs only bounded reads and Codex's idempotent connection query against the already activated VM.

Command:
```bash
CODEX_VM_LIVE_SYSTEMD_PROOF=1 "${CODEX_HOME:-$HOME/.codex}/scripts/proof_run_capture" --feature-dir docs/features/remote-control-managed-workspace --timeout-seconds 120 --note "Verify local remediation plus real systemd oneshot execution and detached-daemon survival"
```

Expected evidence:
- Terraform tests pass while `azurerm_linux_virtual_machine.this.custom_data` is absent and no `azurerm_virtual_machine_run_command`, `remote-exec`, or Terraform local SSH-file resource exists.
- Source guards retain no permanent NSG rule and require the managed-disk destruction guard.
- The production local preparation script invokes Azure Run Command for the exact subscription, resource group, and VM after VM-agent readiness; it never creates an NSG rule or calls SSH.
- The transmitted payload installs byte-identical helpers from the inline bundle before invoking the VM provisioner.
- The production VM provisioner runs the verified installer, preserves existing persistent authentication, mounts before selecting/installing Codex, writes only the expected fstab entry, creates `~/.codex` to the selected projects-disk home, and publishes the CLI from the projects disk.
- SSH hardening permits only local TCP forwarding, and both Remote Control services require `/home/azureadmin/projects`.
- Readiness output contains the exact prepared marker and Ed25519 host key; the Mac files contain the Terraform FQDN, user, identity path, strict host checking, and dedicated known-hosts path.
- The isolated fresh-VM boundary rejects `sshd -t` until `/run/sshd` exists, rejects reloading an inactive SSH service while `ssh.socket` owns activation, and separately requires SSH startup when neither unit is active. The missing-marker scenario requires the remote diagnostic in local failure output.
- A repeated preparation run does not format the disk again or alter persistent authentication state.
- The account helper opens and closes restricted SSH around separate admin-user sign-in and pairing modes, refuses pairing without login, and closes access after an injected failure.
- Persistent-home fixtures cover fresh, existing `.codex`, existing `dot-codex`, unexpected real-home refusal, and mismatched-link refusal.
- Both installed oneshot service files require `KillMode=process` and the supported `ConditionFileIsExecutable` guard, reject the ignored `ConditionPathIsExecutable` spelling observed in the live journal, and authenticated preparation invokes both units through `scripts/codex-vm.sh setup`.
- The isolated preparation boundary injects one failed health start immediately after successful bootstrap and requires setup to retry to a connected result rather than failing at the expected relay transition or bypassing the health check.
- The retained live scenario requires successful executions of both real oneshots, an active health timer, the same live app-server PID and Unix socket after ten seconds, the managed binary identity/version, connected non-timed-out Remote Control JSON, and reset recovery state.
- Daemon recovery covers connected, locally stopped, transient relay degradation, sustained relay degradation with restart/backoff, verified stale-updater, and eight mismatch scenarios without changing authentication, pairing, or settings.
- Recovery rejects `connecting`, timed-out, and missing-environment JSON states; it resets persisted failure/backoff state only after a connected result. A sustained outage proves the first 300-second delay, its 600-second successor, and the 3,600-second maximum cap.
- Azure recovery reconciles the checked-in helper by checksum and invokes it without opening SSH.
- Temporary SSH and SSHFS scenarios retain identity-aware cleanup, input rejection, exact path selection, and failure cleanup.

## Claimed Behavior Coverage
| FEATURE claim | Production activation | Fake boundary | Read-back |
| --- | --- | --- | --- |
| Terraform owns infrastructure only | Terraform production root | Azure providers | No custom data, guest Run Command resource, remote-exec, or permanent ingress |
| Local machine owns preparation | Embedded machine-preparation helper from `scripts/codex-vm.sh` | Azure CLI/VM agent | Exact target, agent wait, Run Command payload, no SSH/NSG call |
| VM is prepared by checked-in code | Transmitted `prepare-codex-vm.sh` and helpers | Package/device/system commands | Installed bytes, command log, fstab, package layout, symlinks, services, SSH files, marker |
| Persistent disk owns Codex state | VM provisioner plus persistent-home helper and dot-codex bootstrap | Block device and SSH | Mount-before-install order, persistent paths, preserved sentinels, exact links |
| Mac trust follows remote read-back | Embedded machine-preparation helper from `scripts/codex-vm.sh` | Azure CLI | Host key returned by VM fixture and exact local files |
| Authentication/pairing are launched locally | Local account helper in sign-in and pair modes | SSH executable | Separate login and start/pair argv, login prerequisite, and access cleanup |
| Reboot recovery remains VM-owned | Installed systemd units plus health helper | Local Codex command fakes plus live Azure Run Command read-back | Mount dependencies, exact unit properties/results, same PID/socket survival, connected JSON, increasing/capped backoff, and signal ordering |
| Temporary access and workspace are safe | Existing production helpers | Azure CLI, public-IP endpoint, SSHFS, diskutil | Exact `/32` rule, identity-aware deletion, path argv, cleanup order |

## Scope
Proves:
- The repository implements a two-phase deployment: Terraform infrastructure first, then one locally launched, read-back-verified preparation command.
- One-time guest preparation no longer originates from cloud-init or Terraform-managed guest execution.
- The transmitted production VM code preserves the established disk, Codex persistence, SSH hardening, and runtime recovery invariants.
- On the configured VM, both real oneshot units were activated through `scripts/codex-vm.sh setup`, completed successfully, and left the same managed app-server PID/socket alive and connected.

Does not prove:
- Live Azure apply/replacement behavior, VM-agent availability during provisioning, real managed-disk formatting or mounting, apt/package network behavior, AppArmor/sshd behavior, ChatGPT authentication, real pairing, VM reboot recovery, backup/restore, or real SSHFS.

False-green risks:
- Provider mocks can accept a Terraform field combination rejected by Azure.
- The isolated VM filesystem and fake device commands cannot reproduce kernel, udev, AppArmor, systemd, apt-lock, or Run Command extension races.
- The provider mock cannot reproduce Linux cgroup behavior. Final evidence therefore requires the bounded live VM scenario after `scripts/codex-vm.sh setup`; a local-only pass is explicitly insufficient for completion.
- Action Run Command returns only bounded final output and allows one active command; a live preparation run can still fail because another command is active or the VM lacks required outbound connectivity.
- The local account proof verifies command ownership, separation, prerequisite enforcement, and cleanup but cannot complete a real device-code or phone pairing flow.

Evidence method:
- Deterministic configuration, subprocess, real Git/package/filesystem, and provider-boundary proof.

Known gaps:
- Live Azure, VM agent, kernel/device, authentication, pairing, backup, restore, and FUSE behavior require an explicitly approved deployment and manual validation.

## Secondary Guards
- `terraform fmt -check -recursive`
- `terraform validate`
- `bash -n` for production and proof scripts
- `git diff --check`
- README and architecture path review

## Environment
- Terraform 1.14+, Bash, Python 3, `jq`, Git, tar, Azure CLI, and standard command fakes under a temporary proof directory.
- The local suite requires no Azure, ChatGPT, SSH-private-key, or live provider credentials. The final remediation attempt additionally requires access to the already configured Terraform subscription and VM for read-only systemd/daemon validation.
- Runner stdout prints Terraform and Bash versions, the mocked-provider/subprocess mode, and the bounded live systemd result when enabled.

## Proof Repair History
- 2026-07-24 live preparation failure: Azure Run Command sequence 1 exited 255 after completing packages, AppArmor, workspace mount, runtime units, persistent Codex installation, and CLI publication. Its retained stderr identifies `Missing privilege separation directory: /run/sshd`; the old local helper then hid that detail behind a generic missing-readiness error.
- Strengthened proof decision: make the isolated `sshd -t` boundary require the fresh-host runtime directory and require a bounded remote diagnostic to reach local stderr when readiness read-back fails.
- 2026-07-24 live rerun: after creating `/run/sshd`, validation passed but final activation failed with `ssh.service is not active, cannot reload.` Read-back confirmed Ubuntu 24.04 has active/enabled `ssh.socket` with inactive/disabled `ssh.service`, so reconciliation must preserve socket activation, reload only an active service, and start SSH only when neither unit is active.
- Evaluator correction after attempt `proof/runs/20260724T195256416123Z`: the proof exercised socket preservation and service startup but did not require reload when `ssh.service` was active; its small diagnostic also could not distinguish a 4096-character tail from unbounded output. The strengthened scenario drives the active-service branch and uses an oversized response with an omitted-prefix sentinel plus an exact extracted-length ceiling.
- Red evidence: attempts `proof/runs/20260724T195905115561Z` and `proof/runs/20260724T195931774177Z` temporarily print the complete oversized response and skip active-service reload respectively; each fails only its strengthened invariant before the production behavior is restored.
- 2026-07-24 user correction: Terraform must create infrastructure first, while every one-time preparation or authentication action is launched from the local machine rather than automatically by cloud-init or a Terraform guest command.
- Revised behavior decision: remove guest preparation and SSH host-key capture from Terraform, add one local preparation entrypoint using Azure Run Command, add a local authentication/pairing entrypoint, and retain systemd only as the post-preparation reboot/runtime exception.
- Revised proof decision: reject Terraform custom data and guest Run Command resources, execute the real local preparation entrypoint through a fake Azure CLI that runs its actual transmitted payload in an isolated VM filesystem, then read back both VM and Mac state. The earlier rendered-cloud-init proof is no longer sufficient because it proves the rejected owner.
- Proof realism refinement before evaluation: corrupt the first transmitted helper at the remote decode boundary and suppress the successful VM readiness marker in a separate run. Both cases must fail without creating local SSH trust files; checksum corruption must fail before the VM preparation marker exists.
- Evaluator correction after attempt `proof/runs/20260724T082455151842Z`: the preparation Azure fake accepted any subscription, resource group, VM, and command ID, while the dot-codex missing-login path still directed users to authenticate on the VM. The strengthened boundary rejects every wrong Azure target field and requires a Mac-owned account command; after sign-in and pairing became separate, missing-login guidance changed to `scripts/codex-vm.sh sign-in`.
- 2026-07-25 user correction: sign-in and device pairing are separate actions. The proof now requires sign-in to avoid Remote Control start/pair, pairing to fail before Remote Control when login is missing, exact Mac-side sign-in guidance, and temporary-SSH cleanup in every mode.
- 2026-07-25 production incident correction: an upstream relay failure caused the health oneshot to restart a detached daemon that systemd then killed through the default control-group policy. The strengthened proof requires explicit detached-daemon preservation, connected-state JSON rather than command/local-process proxies, relay-failure throttling, and post-launch process survival. This closes the false-green gap without replacing the accepted standalone daemon owner.
- Live activation correction after attempt `proof/runs/20260725T141804862454Z`: Ubuntu systemd warned that `ConditionPathIsExecutable` was unknown and ignored. The proof now requires the supported `ConditionFileIsExecutable` directive in both units and rejects the ignored spelling; this strengthens fail-closed startup without changing daemon ownership or recovery behavior.
- Evaluator correction after attempt `proof/runs/20260725T142422473290Z`: direct helper execution with a detached fake process did not prove real systemd/cgroup semantics, parent-reported live observations were not retained executable evidence, and the outage scenario stopped after the first backoff interval. The strengthened proof requires both oneshots to be activated by `scripts/codex-vm.sh setup`, captures a read-only real systemd/PID/socket/connection survival scenario, and proves 300-second, 600-second, and capped 3,600-second restart intervals.
- Red evidence: attempt `proof/runs/20260725T155129974939Z` fails because authenticated setup did not yet activate the bootstrap unit, so a later live read-back could not establish that both corrected unit boundaries had actually executed.
- Live activation after that repair exposed an expected relay transition: the real bootstrap unit completed successfully with its detached processes still running, then the immediately following health start observed `status=errored`, left the healthy local daemon untouched, and caused setup to withhold readiness. The contract now requires bounded retries at that activation boundary; it does not weaken the connected-state oracle or bypass the helper.
- Red evidence: attempt `proof/runs/20260725T155551086677Z` injects the same first-start health failure and fails because setup did not retry it.
- 2026-07-23 persistence correction: Codex installation and state must survive VM replacement on the managed projects disk. The retained persistent-home and dot-codex scenarios continue to require the physical home and CLI under `/home/azureadmin/projects`.
- Earlier retained runs document the stale-daemon, verified-helper reconciliation, temporary-access identity, SSH forwarding, managed-disk destruction guard, and verified-installer proof repairs. This correction changes deployment ownership without weakening those safety invariants.

## Manual Gaps
- After a reviewed and approved manual `terraform apply`, run `scripts/codex-vm.sh setup` from the repository root and inspect its exact VM identity and readiness receipt.
- Then run `scripts/codex-vm.sh sign-in` followed by `scripts/codex-vm.sh pair` and verify device login, Remote Control connectivity, pairing, VM reboot recovery, `findmnt /home/azureadmin/projects`, the loaded AppArmor profile, systemd units/timer, backup protection, and a restore drill.
- After future OS/systemd/Codex upgrades, rerun the live proof mode after activation through `scripts/codex-vm.sh setup`; do not treat the local provider-mock pass alone as sufficient evidence for detached-daemon survival.
