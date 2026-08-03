![Codex on a cloud VM](image.png)

# Codex on a VM

Run Codex on an always-available Ubuntu 24.04 VM in Azure and control it from the Codex app on your Mac. Terraform creates the VM, a 256 GiB persistent workspace at `/home/azureadmin/projects`, and daily backups with 30-day retention and deletion protection.

Your repositories, Codex account, sessions, and tools stay on the persistent disk, so the Mac can sleep and the VM can be replaced without losing the workspace. Remote Control is the normal access path. The self-hosted OpenVPN tunnel is the only interactive network path for VS Code Remote-SSH and SSH; it needs no Azure VPN Gateway and public TCP/22 stays closed.

## Quick start

You need Terraform 1.14+, Azure CLI, and an Azure subscription. Azure resources create ongoing costs.

From the repository root:

```bash
az login

cp deployment/prod/tf/terraform.tfvars.example \
  deployment/prod/tf/terraform.tfvars
cp deployment/prod/tf/backend.hcl.example \
  deployment/prod/tf/backend.hcl
```

Fill in the placeholders in both copied files, then create the infrastructure:

```bash
cd deployment/prod/tf

terraform init -reconfigure -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan

cd ../../..
```

Set up Codex, sign in, and pair your Mac:

```bash
scripts/codex-vm.sh setup
# Connect the existing OpenVPN profile on the Mac.
scripts/codex-vm.sh sign-in
scripts/codex-vm.sh pair
```

Enter the pairing code in the Codex app while using the same ChatGPT account. After pairing, Remote Control is the normal way to use the VM.

## Manage or repair the VM

After pairing, use Codex through the Mac app. You only need the operator console to inspect, change, or repair the VM.

Open the interactive console:

```bash
scripts/codex-vm.sh
```

Or run a workflow directly:

| Task | Command |
| --- | --- |
| Set up or repair Codex | `scripts/codex-vm.sh setup` |
| Sign in to Codex | `scripts/codex-vm.sh sign-in` |
| Pair another device | `scripts/codex-vm.sh pair` |
| Clone or update dot-codex | `scripts/codex-vm.sh dot-codex` |
| Repair private OpenVPN access | `scripts/codex-vm.sh vpn-setup` |

If Codex or Remote Control stops working, run:

```bash
scripts/codex-vm.sh setup
```

Setup is idempotent, does not open SSH, and preserves the persistent Codex home. Run it again after replacing the VM.

## Persistence and access

Keep repositories under `/home/azureadmin/projects`. The workspace and Codex home are on the managed data disk; files elsewhere on the VM may be lost during replacement.

There is no inbound TCP/22 rule or public-SSH fallback. Terraform allows only UDP/1194 to the self-hosted OpenVPN server on the existing VM; it does not create Azure VPN Gateway, Bastion, or another paid Azure service. The existing VM and its network usage still have their normal Azure costs.

Import the existing profile at `~/.config/codex-on-vm/openvpn/codex-on-vm.ovpn` into an OpenVPN-compatible Mac client and connect. VS Code Remote-SSH or direct `ssh codex-on-vm-vpn` then reaches the VM. Source code remains on the VM; Git, language servers, dependencies, and builds run there.

While connected to the VPN, reconcile the existing server/profile or deliberately rotate the trust set:

```bash
scripts/codex-vm.sh vpn-setup
scripts/codex-vm.sh vpn-setup --rotate
```

This repository assumes that initial VPN trust already exists on the Mac and persistent VM disk. It intentionally has no public-SSH bootstrap path. `setup` and Remote Control recovery remain available through Azure Run Command.

Never commit Terraform state, `terraform.tfvars`, `backend.hcl`, private keys, pairing codes, or credentials.

## More detail

- [Operations guide](docs/OPERATIONS.md): deployment, VPN-only recovery, command behavior, and current follow-up work.
- [Architecture](docs/ARCHITECTURE.md): infrastructure ownership, storage, security, and failure boundaries.
- [Operator console contract](docs/features/codex-vm-operator-console/FEATURE.md).
- [Remote Control and workspace contract](docs/features/remote-control-managed-workspace/FEATURE.md).
- [Self-hosted OpenVPN contract](docs/features/self-hosted-openvpn-access/FEATURE.md).
- [dot-codex bootstrap contract](docs/features/dot-codex-vm-bootstrap/FEATURE.md).
