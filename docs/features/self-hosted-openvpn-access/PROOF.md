# Proof

## Done

- Production Terraform plans exactly one standing NSG rule, `AllowOpenVpn` on UDP/1194, and its connection output contains the VPN-only fields without a public SSH alias, temporary-rule name, or local SSHFS mount path.
- Test-mode extraction materializes the VPN helper and VM configurator but no temporary-SSH or workspace helpers. Public command parsing rejects `ssh-open`, `ssh-close`, `workspace-open`, and `workspace-close` before external calls.
- Machine preparation writes only `Host codex-on-vm-vpn`; its strict host identity, key, and known-hosts settings remain intact.
- The public console and focused helpers route account, dot-codex, and VPN maintenance only through `codex-on-vm-vpn`; a disconnected VPN fails visibly before helper activation, SCP, remote mutation, or Azure ingress calls.
- The production OpenVPN helper rejects ordinary repair when local trust is absent, uses real OpenSSL credentials only for explicit rotation, transfers only the server bundle over the VPN alias, persists and activates the native service, restores runtime state, preserves ordinary trust, rotates explicitly, rolls back service failure, and reconciles lost SSH results.
- Production sources, fixture calls, and retained output contain no public TCP/22 rule lifecycle, SSHFS lifecycle, mobile-key workflow, CA private material, client private material, or inline profile contents.

## Command

```bash
"${CODEX_HOME:-$HOME/.codex}/scripts/proof_run_capture" --feature-dir docs/features/self-hosted-openvpn-access --timeout-seconds 90 --note "Exercise VPN-only Codex VM access and reject public SSH or SSHFS fallback"
```

## Scenario: Infrastructure and operator surface

- Producer/activation: Terraform plans the production root with mocked providers; the real console materializes its embedded bundle and parses public commands.
- Consumer: the Terraform graph/output, helper allowlists, console dispatcher, setup SSH-config renderer, and dry-run paths remain production code.
- Read-back: resource count and attributes require only UDP/1194; output keys exclude legacy public-access metadata; extracted paths and help text exclude removed helpers/commands; the generated SSH config contains exactly the VPN alias.
- Fake: Azure providers and unsafe command edges only.
- Catches: a hidden TCP/22 path, retained fallback helper, public alias, SSHFS command, paid VPN resource, cloud-init, or secret Terraform value.

## Scenario: VPN-only trust maintenance

- Producer/activation: the extracted production `openvpn-setup.sh` runs with real OpenSSL against fake Terraform, VPN SSH, SCP, systemd, OpenVPN, and VM filesystem edges.
- Consumer: VPN reachability check, credential validation, server-only transfer, remote transaction, persistent/runtime installation, systemd lifecycle, cleanup, and read-back remain production code.
- Read-back: ordinary repair with missing trust fails before credential creation or remote mutation; every SSH/SCP target is `codex-on-vm-vpn`; no Azure NSG call occurs; certificate chains, key agreement, modes, exact server files, service state, configuration, idempotency, explicit rotation, rollback, lost-result reconciliation, and runtime restoration are observed.
- Fake: Terraform output, SSH/SCP transport, systemd, and OpenVPN daemon only.
- Catches: implicit replacement trust, public bootstrap, secret leakage, client or CA key copied to the VM, missing persistence, permissive routing, accidental trust churn, remote/local split-brain, or service false green.

## Scenario: Disconnected fail-closed behavior

- Producer/activation: the production operator proof injects unavailable VPN reachability before options 2–5, while the VPN trust scenario injects the same failure before maintenance activation.
- Consumer: the centralized production VPN preflight and helper failure paths execute unchanged.
- Read-back: each retained action fails with import/connect guidance before helper activation, while call logs show no SCP, systemd, Azure NSG create/delete, public alias, or credential replacement.
- Fake: only reachability and external command execution.
- Catches: silent public fallback, rotation before connectivity validation, or a disconnected operation that changes local/remote trust.

## Scope

Proves:

- Repository behavior and Terraform state model expose only VPN-based interactive access.
- The real trust and server configuration boundaries remain persistent, transactional, and secret-safe.
- Removed public SSH and SSHFS paths cannot be reached through retained commands or embedded helpers.

Does not prove:

- A live Azure apply, real OpenVPN packet transport, macOS client state, tunnel throughput, or VS Code UI behavior.
- Recovery after simultaneous loss of Mac credentials and persistent server material.

False-green risks:

- Fake SSH/SCP, systemd, and OpenVPN cannot reproduce packet filtering, NAT behavior, daemon/kernel incompatibility, or a third-party client parser.
- Live Mac cleanup is verified separately by exact file read-back, not by the repository proof fixture.

Evidence method:

- Deterministic Terraform and CLI/subprocess proof with real OpenSSL artifacts and fake unsafe outer edges.

Known gaps:

- The VPN client must be connected by the operator before interactive commands; the console does not control the GUI.

## Environment

- Terraform, Bash 3.2, Python 3, OpenSSL, and temporary fixtures.
- No Azure mutation, live SSH target, VPN client, or credentials are required.
- Runner stdout prints the actual runtimes and fake-edge boundary.
