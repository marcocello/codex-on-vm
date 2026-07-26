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

`setup` waits for the Azure VM agent, sends checksummed preparation payloads through Azure Run Command, mounts the managed disk, installs or repairs Codex and Remote Control, verifies readiness, reads the SSH host key, and writes the local `codex-on-vm` SSH configuration. It does not open TCP/22.

The command is idempotent. After a VM replacement, it reuses the attached filesystem and persistent Codex home without formatting existing state. Preview the workflow without making changes:

```bash
scripts/codex-vm.sh --dry-run setup
```

Before a dependent interactive workflow, the console checks whether the VM is prepared and asks before running setup when needed. A non-interactive workflow stops and tells the operator to run setup. A failed setup blocks the requested action.

## Account, pairing, and dot-codex

Sign in from the Mac:

```bash
scripts/codex-vm.sh sign-in
```

This opens temporary `/32` SSH, starts device authentication only when the managed CLI is not already signed in, and closes SSH on success or failure. It does not pair Remote Control.

After sign-in, request a pairing code:

```bash
scripts/codex-vm.sh pair
```

Pairing verifies the existing login, starts Remote Control, prints a short-lived code, and closes SSH on success or failure. Enter the code on the other device using the same ChatGPT account. If login is missing, pairing directs you to `sign-in`.

Clone or safely update the tracked dot-codex configuration:

```bash
scripts/codex-vm.sh dot-codex
```

The default checkout is `/home/azureadmin/projects/dot-codex`. The workflow redirects `~/.codex` to this persistent checkout without moving active state back to the OS disk.

## Recovery

The VM restarts the managed daemon after reboot and checks it every minute. The systemd launchers preserve Codex's detached daemon after the launcher exits, require a connected Remote Control result, and rate-limit restarts during an upstream relay outage.

For Codex installation, Remote Control, mount, or daemon problems, rerun:

```bash
scripts/codex-vm.sh setup
```

Use temporary SSH only if setup cannot complete and direct maintenance is required:

```bash
scripts/codex-vm.sh shell
```

## Repositories and Mac mounts

Keep persistent repositories under `/home/azureadmin/projects`:

```bash
cd /home/azureadmin/projects
git clone <repository-url>
```

The managed disk also holds Codex configuration, authentication, sessions, skills, packages, and the managed CLI. Files stored elsewhere on the VM might not survive replacement.

For occasional access to the VM filesystem from the Mac, install SSHFS:

```bash
brew install --cask sshfs-mac
```

Mount and unmount the projects directory:

```bash
scripts/codex-vm.sh workspace-open
# Work in ~/Volumes/codex-on-vm
scripts/codex-vm.sh workspace-close
```

Mount another absolute VM directory when needed:

```bash
scripts/codex-vm.sh workspace-open /home/azureadmin
```

Run heavy Git and build operations on the VM. Avoid writing to the same working tree from both machines at once.

## Access model

There is no permanent inbound SSH rule. `shell` opens access for the current Mac IP, connects, and closes it on success, failure, or interruption. `workspace-open` keeps the same restricted access for the mount lifecycle, and `workspace-close` unmounts before closing SSH.

If an interrupted operation leaves access behind, remove it and verify that the port is closed:

```bash
scripts/codex-vm.sh ssh-close
```

This is operator-controlled, JIT-style access with no automatic server-side expiry. Microsoft Defender JIT remains an optional paid alternative.

Never commit Terraform state, `terraform.tfvars`, `backend.hcl`, private keys, pairing codes, or credentials.

## Current follow-up work

The recovery path protects the managed daemon from systemd teardown and rate-limits relay-outage restarts. Remaining reliability work:

- Serialize timer and Azure-triggered recovery through one VM-side lock and add a concurrent-recovery regression.
- Add a controlled reboot verification workflow to `scripts/codex-vm.sh`.
- Choose a Codex upgrade policy: repository-pinned releases or managed auto-updates with a post-update compatibility check.

Implement and activate these changes through `scripts/codex-vm.sh`. Until the concurrency lock is added, avoid overlapping setup or dot-codex recovery operations.
