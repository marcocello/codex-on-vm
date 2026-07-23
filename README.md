![Codex on a cloud VM](image.png)

# Codex on a VM

This repository creates an always-available Codex machine in Azure. The VM keeps your repositories and tools online, so your Mac does not need to stay awake.

After setup, connect from another device through Codex Remote Control pairing. SSH is only opened temporarily for setup or maintenance and remains closed during normal use. Repositories live on a separate managed disk mounted at `/home/azureadmin/projects`.

## What Terraform creates

- Ubuntu 24.04 VM with Codex installed for `azureadmin`.
- No permanent inbound SSH rule.
- 256 GiB persistent disk mounted at `/home/azureadmin/projects`.
- Daily backup with 30-day retention and deletion protection.
- Local SSH configuration for the `codex-on-vm` alias.

For the storage and security decisions, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Deploy

You need Terraform 1.14+, Azure CLI, and an authenticated Azure session:

```bash
az login
```

Create the ignored `deployment/prod/tf/terraform.tfvars`:

```hcl
subscription_id = "<azure-subscription-id>"
owner           = "<owner-or-team>"
```

Keep your Azure state-backend settings in the ignored `deployment/prod/tf/backend.hcl`.

> If you are replacing the previous Azure Files deployment, back up the share first. This Terraform configuration does not migrate its data, and the new disk starts empty.

Apply:

```bash
cd deployment/prod/tf

terraform init \
  -reconfigure \
  -backend-config=backend.hcl

terraform plan -out=tfplan
terraform apply tfplan
```

Review the plan before applying it. Azure resources create ongoing costs.

## First setup and device pairing

Open temporary SSH access for your current public IP, then connect to the VM:

```bash
scripts/ssh-open.sh
ssh codex-on-vm
```

On the VM:

```bash
cloud-init status --wait
findmnt /home/azureadmin/projects
test -x ~/.codex/packages/standalone/current/codex
codex login --device-auth
codex remote-control start
codex remote-control pair
```

Enter the short-lived pairing code on the other device using the same ChatGPT account. Then exit the VM and close SSH:

```bash
exit
scripts/ssh-close.sh
```

From then on, use the paired device through Remote Control. Reopen SSH only when you need to configure, maintain, or recover the VM, and close it again when finished.

The VM restarts the managed daemon after reboot and checks it every minute. If Remote Control still disappears, run this from the repository checkout on the Mac:

```bash
scripts/remote-control-recover.sh
```

The command uses Azure Run Command without opening SSH. It verifies the checked-in VM recovery helper, installs it only when the VM copy differs, and then runs it; repeating the command does not rewrite an already matching helper. Use temporary SSH only if Azure Run Command cannot recover the daemon.

## Repositories

Keep persistent repositories under `/home/azureadmin/projects`:

```bash
cd /home/azureadmin/projects
git clone <repository-url>
```

The workspace disk survives VM replacement. Files stored elsewhere on the VM might not.

## Mount the projects disk on the Mac

Install SSHFS once:

```bash
brew install --cask sshfs-mac
```

Mount and unmount from the repository root:

```bash
scripts/workspace-open.sh
# Work in ~/Volumes/codex-on-vm
scripts/workspace-close.sh
```

The default remote directory is `/home/azureadmin/projects`. To mount the complete `azureadmin` home directory instead, pass one absolute remote path:

```bash
scripts/workspace-open.sh /home/azureadmin
```

Use SSHFS for occasional local access. Run heavy Git and build operations on the VM, and avoid writing to the same working tree from both machines at once.

## Access model

There is no permanent inbound SSH rule. `scripts/ssh-open.sh` creates a temporary TCP/22 rule restricted to your current public IPv4 `/32`; `scripts/ssh-close.sh` removes the rule and verifies that the port is closed again.

This is operator-controlled, JIT-style access with no automatic server-side expiry. Always run the close script when setup or maintenance is complete. Microsoft Defender JIT remains an optional paid upgrade.

Never commit Terraform state, `terraform.tfvars`, `backend.hcl`, private keys, pairing codes, or credentials.
