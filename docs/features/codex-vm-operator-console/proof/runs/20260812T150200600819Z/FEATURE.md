# Codex VM operator console

## Goal

Provide one visible Mac terminal entrypoint for VM setup, Codex account actions, dot-codex maintenance, telegram-to-agents installation, and OpenVPN maintenance without exposing public SSH.

## Behavior

- Running `scripts/codex-vm.sh` opens a single-action menu with exactly:
  1. Set up or repair Codex on the VM.
  2. Sign in to Codex.
  3. Pair a device.
  4. Clone or update dot-codex.
  5. Install or update telegram-to-agents.
  6. Repair OpenVPN.
- The menu has no shell, status, mount, close, or exit option. It does not clear previous terminal output, runs the selected action once, prints its result, and returns to the shell.
- Explicit commands are `setup`, `sign-in`, `pair`, `dot-codex`, `telegram-to-agents`, `vpn-setup [--rotate]`, `menu`, and `help`. Removed commands are rejected before external calls.
- Every user-selected action prints its checks, activation stage, subprocess output, and final success or failure in the terminal. A blocking external check prints its target before activation and periodic elapsed-time progress while it remains pending.
- Before options 2–6, the console visibly reads the Terraform target, verifies the active Azure subscription, checks the preparation marker through Azure Run Command with periodic progress, and then visibly probes `codex-on-vm-vpn` with bounded non-interactive SSH.
- A disconnected VPN stops before the action helper. The message instructs the operator to import the existing profile into the Mac OpenVPN client when necessary, connect it, and retry.
- Option 1 is the deliberate exception to the VPN preflight: setup is the Azure Run Command recovery path that can restore the VM and persistent OpenVPN service when direct access is unavailable.
- Option 6 reconciles the existing OpenVPN trust/server configuration without changing trust. The explicit `vpn-setup --rotate` command intentionally replaces the trust set. Neither path is a first-time bootstrap after loss of both Mac and persistent server trust.
- The console embeds six Mac helpers and seven VM payloads, materializes only the needed private runtime bundle, and removes it after the action.
- The telegram-to-agents action clones `https://github.com/marcocello/telegram-to-agents` into `/home/azureadmin/projects/telegram-to-agents` when absent, or requires the existing checkout to be clean, on a branch tracking the expected origin, and fast-forwardable before updating it.
- The action creates or refreshes the checkout-local `.venv`, installs the checked-out package there, and exposes its CLI through `~/.local/bin/telegram-to-agents`. A missing current configuration triggers interactive onboarding over the existing VPN SSH session; an existing installed user service is restarted and must become active after an update. The action never supplies model, prompt, permission, sandbox, tool, or agent configuration.
- Setup writes one strict `Host codex-on-vm-vpn` configuration plus dedicated host trust. No action creates a TCP/22 NSG rule.

## Constraints

- Terraform apply remains manual.
- `vpn-setup` accepts only the optional `--rotate` flag; other actions accept no positional arguments.
- Help and dry-run remain mutation-free and show the same action/check ordering.
- Secrets, authentication material, and pairing codes are never copied into Terraform output or hidden by the console.

## Non-goals

- Installing or controlling the Mac OpenVPN client.
- Public SSH bootstrap, repository-managed SSH shell/status commands, SSHFS/FUSE mounts, Azure VPN Gateway, Bastion, or deployment orchestration.
