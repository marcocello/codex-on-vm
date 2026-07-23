# Storage Managed Identity

> Superseded by `docs/features/remote-control-managed-workspace`. This contract and its captured runs are historical and do not describe the current production Terraform root.

## Summary
Mount the VM workspace from Azure Files without granting the VM permission to list or regenerate storage-account keys and without persisting an account key on the VM.

## Desired Behavior
- A dedicated user-assigned managed identity authenticates the Ubuntu 24.04 VM to Azure Files over SMB OAuth.
- The storage account has SMB OAuth enabled and the VM identity has the Azure role required for managed-identity SMB mounts.
- Cloud-init installs the supported Azure Files authentication client, configures automatic credential refresh, and mounts `/workspace` with Kerberos rather than an account key.
- The VM has no Storage Account Key Operator role, does not call the storage `listKeys` API, and does not write `/etc/smbcredentials`.
- Existing Mac SMB access using storage `key2` remains available as a separate workflow.

## Constraints
- Azure Files managed-identity SMB authentication is an Azure preview feature and must use the documented Ubuntu 24.04 client path.
- The pinned AzureRM provider does not expose the SMB OAuth property, so only that unsupported property is managed with AzAPI; AzureRM continues to own the storage account lifecycle.
- The documented `Storage File Data SMB MI Admin` role is scoped to the dedicated storage account. The account contains only the workspace share.
- The managed identity and its role assignment must exist before VM cloud-init starts.
- No live `terraform apply`, VM replacement, or Azure mutation is part of this implementation pass.

## Implementation Routing
- Required skills: coding-feature-execute, coding-proof-author, coding-research
