![Codex on a cloud VM](image.png)

# Codex on a VM

This repository creates an always-available development machine for Codex in Azure. You can connect to the same machine from a Mac or mobile device over public key-only SSH and continue working in the same `/workspace` directory.

## Why run Codex on a VM?

Use this when you want one development environment that is reachable from more than one device. Repositories and tools stay on the VM, so switching between Mac and mobile does not require copying a checkout or recreating the setup on each device. The VM must be running and incurs Azure usage costs.

The workspace is stored on Azure Files rather than only on the VM disk. This keeps project files available if the VM is replaced and also lets you mount the same workspace on your Mac when you want to use local tools.

Terraform creates the Azure VM, network, persistent file share, separate Mac and mobile SSH access, and local SSH configuration.

The VM image and direct provisioning artifacts are version-pinned. Codex and the Microsoft repository bootstrap package are SHA-256 verified before root installation; upgrades require an explicit repository change rather than following a mutable `latest` installer.

## 1. Configure

The ignored `deployment/prod/tf/terraform.tfvars` needs only:

```hcl
subscription_id = "<azure-subscription-id>"
owner           = "<owner-or-team>"
```

Keep the existing ignored `backend.hcl` with your Azure state-backend coordinates.

## 2. Apply

```bash
cd deployment/prod/tf

terraform init \
  -reconfigure \
  -backend-config=backend.hcl

terraform apply
```

During planning, Terraform ensures these local files exist:

```text
~/.ssh/codex-on-vm-mac
~/.ssh/codex-on-vm-mac.pub
~/.ssh/codex-on-vm-mobile.pkcs8.pem
~/.ssh/codex-on-vm-mobile.pkcs8.pem.pub
```

Existing matching keypairs are preserved. `terraform apply` can create billable Azure resources and may replace the VM when SSH or cloud-init settings change, so review the plan before approving it.

## 3. Connect from the Mac

Verify the VM host-key fingerprint through Azure before adding it to `~/.ssh/known_hosts`. Terraform writes the SSH alias `codex-on-vm` to `~/.ssh/config.d/codex-on-vm.conf`.

```bash
ssh codex-on-vm
```

## 4. Use the persistent workspace

The Azure file share is mounted on the VM at `/workspace`. Files and project folders that need to persist must be stored below this path.

When creating a new project or selecting a folder in Codex, choose `/workspace` or create the project inside it, for example `/workspace/my-project`.

## 5. Connect from mobile

Import `~/.ssh/codex-on-vm-mobile.pkcs8.pem` into the mobile SSH connection. It is an Ed25519 PKCS#8 PEM file supported by the mobile importer. Do not send this private key through email, chat, Git, or cloud notes.

Configure the mobile connection with:

- Host: `ssh_fqdn` from `terraform output -json connection`
- Port: `22`
- User: `azureadmin`
- Private key: the imported mobile key
- Workspace: `/workspace`

Confirm the mobile host fingerprint matches the fingerprint verified through Azure.

## 6. Mount the workspace on the Mac

From the repository root:

```bash
scripts/smb-open.sh
# Work in ~/Volumes/codex-on-vm
scripts/smb-close.sh
```

`smb-open.sh` discovers the current Mac public IPv4, temporarily allows it in the Azure Storage firewall, copies Storage `key2` to the clipboard for at most 60 seconds, clears the clipboard after the mount attempt, and mounts the share. `smb-close.sh` unmounts it, verifies removal of that exact firewall rule, and rotates `key2`; incomplete cleanup retains recovery state so the close command can be retried.

The client IP is never stored in Terraform. The VM accesses the same share through its subnet using its dedicated managed identity and SMB OAuth; it does not retrieve or store an account key. Direct Mac access continues to use Storage `key2`, and outbound TCP 445 must be available for that workflow.

Terraform also configures 14-day file-share soft delete, a daily Azure Backup snapshot retained for 30 days, and a `CanNotDelete` lock on the storage account. A live restore drill is still required before treating the workspace as operationally recoverable.

Never commit `terraform.tfvars`, `backend.hcl`, state files, private keys, screenshots, or generated proof evidence.
