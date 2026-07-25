![Codex on a cloud VM](image.png)

# Codex on a VM

This repository creates an always-available Codex machine in Azure. The VM keeps your repositories and tools online, so your Mac does not need to stay awake.

After setup, connect from another device through Codex Remote Control pairing. SSH is only opened temporarily for setup or maintenance and remains closed during normal use. Repositories live on a separate managed disk mounted at `/home/azureadmin/projects`.

## What Terraform creates

- Ubuntu 24.04 VM ready for locally launched preparation.
- No permanent inbound SSH rule.
- 256 GiB persistent disk attached at LUN 0 for `/home/azureadmin/projects`.
- Daily backup with 30-day retention and deletion protection.

Terraform creates infrastructure only. Before VM creation, it calls a private `scripts/codex-vm.sh` entrypoint to create or verify the Mac Ed25519 key pair; Terraform receives only the public key. It does not run cloud-init preparation, execute a VM Run Command, or write local SSH trust files.

For the storage and security decisions, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## One operator command

Run the console from the repository root:

```bash
scripts/codex-vm.sh
```

With no arguments it opens an interactive menu and returns to the menu after each action. The same workflows are available as explicit subcommands for terminals, scripts, and recovery:

```bash
scripts/codex-vm.sh help
scripts/codex-vm.sh status
```

The console runs on the Mac and is the repository's only production shell script. It contains the focused local helpers and VM payloads that own Azure targeting, checksummed VM preparation, verified installation, authentication, temporary SSH, workspace mounts, and cleanup.

## Prerequisites

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

## Deploy Terraform manually

```bash
cd deployment/prod/tf

terraform init \
  -reconfigure \
  -backend-config=backend.hcl

terraform plan -out=tfplan
terraform apply tfplan
```

Terraform is always run manually and is not part of the operator console. Azure resources create ongoing costs, so review the plan before applying it.

Removing the former cloud-init payload can require replacing an existing VM. Confirm that the plan preserves the separately managed workspace disk and its protection before applying; OS-disk-only state will not survive replacement.

After Terraform completes, return to the repository root and set up Codex:

```bash
cd ../../..
scripts/codex-vm.sh setup
```

You can also open the interactive menu immediately and choose another workflow. Before pairing, dot-codex synchronization, SSH, or workspace access, the console checks `/var/lib/codex-on-vm/prepared` against the current Terraform Codex version and projects mount. If preparation is required in an interactive terminal, it asks whether to run `setup` first. Declining cancels the selected action. A non-interactive command stops with an instruction to run `scripts/codex-vm.sh setup`, and a failed accepted setup prevents the requested workflow from running.

This command waits for the Azure VM agent, extracts the inline provisioner and supporting payloads from `scripts/codex-vm.sh`, sends them through Azure Run Command, verifies their checksums on the VM, prepares and mounts the disk, installs or repairs Codex and Remote Control, reads back readiness and the SSH host key, and only then writes the local `codex-on-vm` SSH configuration. It does not open TCP/22.

Rerun `setup` after replacing the VM. It reuses the attached filesystem and persistent Codex home without formatting existing state. Preview it without changing anything with `scripts/codex-vm.sh --dry-run setup`.

## First authentication and device pairing

Launch authentication and pairing from the Mac:

```bash
scripts/codex-vm.sh pair
```

The workflow opens temporary `/32` SSH, launches device authentication only when needed, starts Remote Control, prints the short-lived pairing code, and closes SSH on success or failure. Enter the code on the other device using the same ChatGPT account.

From then on, use the paired device through Remote Control. Reopen SSH only when you need to configure, maintain, or recover the VM, and close it again when finished.

To clone or safely update the tracked `dot-codex` configuration from GitHub, run:

```bash
scripts/codex-vm.sh dot-codex
```

Its default VM clone is `/home/azureadmin/projects/dot-codex`, and it redirects `~/.codex` to that persistent checkout without moving active state back to the VM OS disk.

The VM restarts the managed daemon after reboot and checks it every minute. If Codex or Remote Control needs repair, rerun:

```bash
scripts/codex-vm.sh setup
```

The idempotent setup workflow uses Azure Run Command without opening SSH and preserves the persistent Codex home.

## All operator scenarios

| Scenario | Command |
| --- | --- |
| Interactive menu | `scripts/codex-vm.sh` |
| Set up or repair Codex after manual Terraform or a VM replacement | `scripts/codex-vm.sh setup` |
| Sign in and pair a device | `scripts/codex-vm.sh pair` |
| Clone or update dot-codex from GitHub | `scripts/codex-vm.sh dot-codex` |
| Open an interactive shell with automatic SSH cleanup | `scripts/codex-vm.sh shell` |
| Close retained temporary SSH | `scripts/codex-vm.sh ssh-close` |
| Mount the default projects directory on the Mac | `scripts/codex-vm.sh workspace-open` |
| Mount another absolute VM directory | `scripts/codex-vm.sh workspace-open /home/azureadmin` |
| Unmount the workspace and close SSH | `scripts/codex-vm.sh workspace-close` |
| Inspect VM, agent, SSH, trust, and mount state | `scripts/codex-vm.sh status` |

## Repositories

Keep persistent repositories under `/home/azureadmin/projects`:

```bash
cd /home/azureadmin/projects
git clone <repository-url>
```

The workspace disk survives VM replacement. Codex configuration, authentication, sessions, skills, packages, and its CLI publication also live on this disk; `scripts/codex-vm.sh setup` recreates `~/.codex` as a compatibility symlink after Terraform attaches the disk to a replacement VM. Files stored elsewhere on the VM might not survive.

## Mount the projects disk on the Mac

Install SSHFS once:

```bash
brew install --cask sshfs-mac
```

Mount and unmount from the repository root:

```bash
scripts/codex-vm.sh workspace-open
# Work in ~/Volumes/codex-on-vm
scripts/codex-vm.sh workspace-close
```

The default remote directory is `/home/azureadmin/projects`. To mount the complete `azureadmin` home directory instead, pass one absolute remote path:

```bash
scripts/codex-vm.sh workspace-open /home/azureadmin
```

Use SSHFS for occasional local access. Run heavy Git and build operations on the VM, and avoid writing to the same working tree from both machines at once.

## Access model

There is no permanent inbound SSH rule and no standalone console action that leaves SSH open. `scripts/codex-vm.sh shell` opens restricted access, connects, and closes it on success, failure, or interruption. Workspace mounting owns the same restricted access for the mount lifecycle and closes it during `workspace-close`. If an interrupted or legacy operation leaves access behind, `scripts/codex-vm.sh ssh-close` removes the rule and verifies that the port is closed again.

This is operator-controlled, JIT-style access with no automatic server-side expiry. Always run `scripts/codex-vm.sh ssh-close` when setup or maintenance is complete. Microsoft Defender JIT remains an optional paid upgrade.

Never commit Terraform state, `terraform.tfvars`, `backend.hcl`, private keys, pairing codes, or credentials.
