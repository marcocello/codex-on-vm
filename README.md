![Codex on a cloud VM](image.png)

# codex-on-vm

This repository creates an always-available Codex development machine in Azure. Mac and mobile connect directly through hardened, public key-only SSH, while Azure Files keeps `/workspace` persistent.

Terraform automatically creates separate local Ed25519 keypairs for Mac and mobile when they do not already exist. Private keys stay as mode-`0600` files under `~/.ssh` and are never stored in Terraform state.

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
scripts/smb-open
# Work in ~/Volumes/codex-on-vm
scripts/smb-close
```

`smb-open` discovers the current Mac public IPv4, temporarily allows it in the Azure Storage firewall, copies Storage `key2` to the clipboard for the macOS password prompt, and mounts the share. `smb-close` unmounts it and removes that exact firewall rule.

The client IP is never stored in Terraform. The VM accesses the same share through its subnet using Storage `key1`. Outbound TCP 445 must be available for direct Mac SMB access.

Never commit `terraform.tfvars`, `backend.hcl`, state files, private keys, screenshots, or generated proof evidence.
