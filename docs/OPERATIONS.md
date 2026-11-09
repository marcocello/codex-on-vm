# Operations

This guide contains the operational detail behind the two-minute flow in the [README](../README.md).

## Requirements and local configuration

Install Terraform 1.14+ and Azure CLI, then authenticate:

```bash
az login
```

Copy the ignored configuration examples:

```bash
cp deployment/prod/tf/terraform.tfvars.example \
  deployment/prod/tf/terraform.tfvars
cp deployment/prod/tf/backend.hcl.example \
  deployment/prod/tf/backend.hcl
```

Set at least the subscription and owner values in `terraform.tfvars`:

```hcl
subscription_id = "<azure-subscription-id>"
owner           = "<owner-or-team>"
```

Fill in the Azure state-backend settings in `backend.hcl`.

If you are replacing the previous Azure Files deployment, back up the share first. This configuration does not migrate its data, and the managed disk starts empty.

## Deploy or replace the VM

Terraform is always run manually:

```bash
cd deployment/prod/tf

terraform init \
  -reconfigure \
  -backend-config=backend.hcl

terraform plan -out=tfplan
terraform apply tfplan
```

Review the plan before applying because Azure resources create ongoing costs. Removing the former cloud-init payload can require replacing an existing VM. Confirm that the plan preserves the separately managed workspace disk and its protection; data stored only on the OS disk will not survive replacement.

After Terraform completes, return to the repository root:

```bash
cd ../../..
scripts/codex-vm.sh setup
```

Terraform creates infrastructure only. Before VM creation, it calls a private `scripts/codex-vm.sh` entrypoint to create or verify the Mac Ed25519 key pair and receives only the public key. It does not prepare the guest, execute a VM Run Command, or write local SSH trust files.

`setup` waits for the Azure VM agent, sends checksummed preparation payloads through Azure Run Command, mounts the managed disk, installs or repairs Codex and Remote Control, verifies readiness, reads the SSH host key, and writes the local `codex-on-vm-vpn` SSH configuration. It does not open TCP/22.

The command is idempotent. After a VM replacement, it reuses the attached filesystem and persistent Codex home without formatting existing state. Preview the workflow without making changes:

```bash
scripts/codex-vm.sh --dry-run setup
```

Before a dependent interactive workflow, the console checks whether the VM is prepared and asks before running setup when needed. A non-interactive workflow stops and tells the operator to run setup. A failed setup blocks the requested action.

## Account, pairing, dot-codex, and telegram-to-agents

Connect the existing OpenVPN profile on the Mac before using an interactive workflow. Then sign in:

```bash
scripts/codex-vm.sh sign-in
```

This verifies that `codex-on-vm-vpn` is reachable and starts device authentication only when the managed CLI is not already signed in. It does not pair Remote Control.

After sign-in, request a pairing code:

```bash
scripts/codex-vm.sh pair
```

Pairing verifies the existing login, starts Remote Control, and prints a short-lived code over the VPN. Enter the code on the other device using the same ChatGPT account. If login is missing, pairing directs you to `sign-in`.

Clone or safely update the tracked dot-codex configuration:

```bash
scripts/codex-vm.sh dot-codex
```

The default checkout is `/home/azureadmin/projects/dot-codex`. The workflow redirects `~/.codex` to this persistent checkout without moving active state back to the OS disk.

Install or safely update telegram-to-agents:

```bash
scripts/codex-vm.sh telegram-to-agents
```

The default checkout is `/home/azureadmin/projects/telegram-to-agents`. The workflow creates a checkout-local virtual environment, publishes `~/.local/bin/telegram-to-agents`, runs onboarding on first installation, and restarts an existing `telegram-to-agents.service` after an update. It refuses dirty, wrong-origin, detached, or divergent checkouts.

## Private OpenVPN and VS Code

Terraform owns only the standing UDP/1194 NSG rule. It does not create Azure VPN Gateway, Bastion, another VM, or a paid security plan. The self-hosted OpenVPN Community server runs on the existing VM, so this adds no separate paid VPN resource; the VM and its network traffic still retain their ordinary Azure costs.

The supported configuration starts with an existing Mac profile at `~/.config/codex-on-vm/openvpn/codex-on-vm.ovpn` and matching server trust on the persistent VM disk. Import the profile into an OpenVPN-compatible macOS client and connect. Initial trust bootstrap after losing both copies is intentionally not provided through public SSH.

While connected, reconcile the existing trust set and OpenVPN service:

```bash
scripts/codex-vm.sh vpn-setup
```

This Mac-launched script is intentionally separate from Terraform and cloud-init. It requires the connected VPN, installs only the server bundle through `codex-on-vm-vpn`, verifies `openvpn-server@codex-vm.service`, and writes a strict single-host SSH configuration. Secrets never enter Terraform state or Azure Run Command.

The profile is:

```text
~/.config/codex-on-vm/openvpn/codex-on-vm.ovpn
```

Verify the tunnel:

```bash
ssh codex-on-vm-vpn
```

In VS Code, install the Remote - SSH extension, run `Remote-SSH: Connect to Host…`, and select `codex-on-vm-vpn`. This keeps the source tree, Git, language servers, dependencies, and builds on the Linux VM, which is the preferred daily workflow.

Ordinary `vpn-setup` is idempotent and repairs the VM without changing trust. To deliberately revoke the old client and replace the complete trust set, run:

```bash
scripts/codex-vm.sh vpn-setup --rotate
```

Rotation keeps one private local backup for recovery. Reimport the new profile after a successful rotation. The console does not install or control the macOS OpenVPN application and does not disconnect an active tunnel.

## Recovery

The VM restarts the managed daemon after reboot and checks it every minute. The systemd launchers preserve Codex's detached daemon after the launcher exits, require a connected Remote Control result, and rate-limit restarts during an upstream relay outage.

For Codex installation, Remote Control, or daemon problems, rerun:

```bash
scripts/codex-vm.sh setup
```

For direct maintenance, connect OpenVPN and then use the generated private alias:

```bash
ssh codex-on-vm-vpn
```

## Memory protection

VM preparation configures a 2 GiB swap file on the OS disk and a one-minute memory sampling timer. If another swap configuration exists, preparation stops for inspection. After an OS-disk replacement, run `scripts/codex-vm.sh setup` to restore the protection.

Read recent samples and warnings on the VM:

```bash
journalctl -t codex-vm-memory --since "1 hour ago"
systemctl status codex-vm-memory-sample.timer
swapon --show
```

A warning indicates available memory below 15%, swap usage of at least 75%, or full memory pressure of at least 10% over one minute. Warnings stay in the VM journal; they do not send external notifications. Swap can reduce short spikes, but it cannot prevent overload from sustained demand.

## Repositories and VS Code

Keep persistent repositories under `/home/azureadmin/projects`:

```bash
cd /home/azureadmin/projects
git clone <repository-url>
```

The managed disk also holds Codex configuration, authentication, sessions, skills, packages, and the managed CLI. Files stored elsewhere on the VM might not survive replacement.

Open `/home/azureadmin/projects` through VS Code Remote-SSH using `codex-on-vm-vpn`. The editor interface stays on the Mac while file access, terminals, extensions, Git, and builds execute on the VM's native filesystem.

## Access model

There is no inbound TCP/22 rule, temporary rule, or SSHFS fallback. `sign-in`, `pair`, `dot-codex`, `telegram-to-agents`, and `vpn-setup` visibly fail before remote mutation when `codex-on-vm-vpn` is unreachable. The console does not connect or disconnect the Mac OpenVPN client.

Never commit Terraform state, `terraform.tfvars`, `backend.hcl`, private keys, pairing codes, or credentials.

## Current follow-up work

The recovery path protects the managed daemon from systemd teardown and rate-limits relay-outage restarts. Remaining reliability work:

- Serialize timer and Azure-triggered recovery through one VM-side lock and add a concurrent-recovery regression.
- Add a controlled reboot verification workflow to `scripts/codex-vm.sh`.
- Choose a Codex upgrade policy: repository-pinned releases or managed auto-updates with a post-update compatibility check.

Implement and activate these changes through `scripts/codex-vm.sh`. Until the concurrency lock is added, avoid overlapping setup or dot-codex recovery operations.
