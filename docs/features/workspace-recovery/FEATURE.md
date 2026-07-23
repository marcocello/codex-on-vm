# Workspace Recovery

> Superseded by `docs/features/remote-control-managed-workspace`. This contract and its captured runs are historical and do not describe the current production Terraform root.

## Summary
Make the persistent Azure Files workspace recoverable from accidental or malicious deletion and prevent accidental storage-account removal.

## Desired Behavior
- File-share soft delete is explicitly enabled with 14-day retention.
- Azure Backup protects the workspace every day and retains daily recovery points for 30 days.
- The storage firewall allows the trusted Azure-services exception required by Azure Backup while continuing to deny unlisted networks.
- The storage account is protected by an Azure `CanNotDelete` management lock.
- Backup resources are colocated with the storage account and managed in Terraform.

## Constraints
- The storage account remains in Austria East and keeps its current LRS replication setting.
- Vault-standard Azure Files backup is not supported in Austria East, so this feature uses Recovery Services snapshot-tier backup. Moving regions and migrating existing workspace data are not part of this feature.
- The backup policy runs daily at `02:00` UTC and retains 30 daily recovery points.
- Applying the management lock intentionally prevents storage-account deletion until an operator explicitly removes the lock.
- The storage firewall bypass is limited to `AzureServices`; broad public access and additional bypass categories remain excluded.
- No live `terraform apply`, paid backup activation, destructive restore, or Azure mutation is part of this implementation pass.

## Implementation Routing
- Required skills: coding-feature-execute, coding-proof-author, coding-research
