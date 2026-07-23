# Proof Plan

> Superseded by `docs/features/remote-control-managed-workspace`. This proof is retained as historical evidence only.

## Definition Of Done
- A mocked Terraform plan renders explicit 14-day file-share soft delete.
- The plan includes a Recovery Services vault, storage registration, daily snapshot backup policy with 30-day retention, and protected workspace share.
- The plan grants the `AzureServices` firewall bypass required for Azure Backup without changing the default deny rule.
- The plan includes a `CanNotDelete` lock scoped to the storage account.

## Primary Proof
Type: static-doc

Boundary:
- Producer: Root Terraform configuration for the Azure Files workspace.
- Activation path: `terraform test` creates a provider-mocked plan through the real module entrypoint.
- Consumer: Terraform provider schemas, resource graph, and native test assertions.
- Durable state: captured Terraform plan and assertions in the evidence bundle.
- Read-back: Terraform test output and planned recovery-resource attributes.
- Unsafe edge: Azure Backup and Azure Resource Manager calls are replaced by Terraform mock providers.

Command:
```bash
scripts/proof_run_capture --serious --feature-dir docs/features/workspace-recovery --source-path deployment/prod/tf/storage.tf --source-path deployment/prod/tf/backup.tf --source-path deployment/prod/tf/tests/workspace_recovery.tftest.hcl --source-path docs/features/workspace-recovery/proof/run.sh --behavior-boundary "Terraform configuration -> mocked provider plan -> soft-delete backup and lock assertions" --oracle-scope "$(cat docs/features/workspace-recovery/PROOF.md)" --notes "Workspace plan enforces 14-day soft delete, daily 30-day backup, and deletion lock" -- docs/features/workspace-recovery/proof/run.sh
```

Expected evidence:
- Terraform test reports the workspace recovery run as passed.
- Planned resources expose the exact retention, backup tier, protected share, and lock level.

## Claimed Behavior Coverage
| FEATURE claim | Real production entrypoint proof drives | Fake boundary used | Read-back |
| --- | --- | --- | --- |
| Share deletion is recoverable for 14 days | Root Terraform plan | AzureRM mock provider | Storage `retention_policy.days` |
| Daily recovery points are retained for 30 days | Root Terraform plan | Azure Backup calls omitted | Planned backup frequency, time, tier, and retention |
| Workspace is registered and protected | Root Terraform plan | Azure Backup calls omitted | Planned container and protected-share references |
| Backup can reach the firewalled account | Root Terraform plan | Azure Backup calls omitted | Exact firewall bypass and default action |
| Storage account cannot be deleted accidentally | Root Terraform plan | AzureRM mock provider | Planned management-lock scope and level |

## Fake Boundary Ledger
- Fake: AzureRM, AzureAD, External, Local, and AzAPI provider network operations.
- Allowed because: live backup registration and lock creation mutate paid Azure resources and are outside this pass.
- Not faked: Terraform parsing, provider schemas, root-module planning, resource references, retention values, backup tier, and lock level.

## Proof Scope
Proves:
- The local Terraform plan explicitly configures the supported recovery controls and protects the intended workspace share.

Does not prove:
- Live backup registration, first recovery-point creation, backup job completion, restore success, lock enforcement, Azure billing, or service availability in the subscription.

False-green risks:
- Azure may reject backup registration or policy activation despite a provider-valid mocked plan.
- A successful backup configuration does not prove data can be restored until a live restore drill is performed.

Evidence strength:
- deterministic local configuration proof with live backup and restore gaps

## Secondary Guards
- `terraform fmt -check -recursive`
- `terraform validate`

## Environment And Data
- Terraform 1.14+ and initialized provider plugins.
- No Azure credentials or live resources are used by the primary proof.

## Anti-Gaming Review
- Fake pass risk: declaring a vault without protecting the workspace share.
- Proof catch: the plan must include a protected-file-share resource referencing the workspace and policy.
- Fake pass risk: relying on Azure defaults for soft delete.
- Proof catch: the test requires an explicit 14-day share retention policy.
- Fake pass risk: adding backups but leaving the storage account deletable.
- Proof catch: the test requires a `CanNotDelete` lock scoped to the planned storage account.
- Fake pass risk: configuring backup behind a firewall that blocks the backup service.
- Proof catch: the test requires default deny plus the exact `AzureServices` trusted-service bypass.
- Broken implementation that would still pass: Azure could accept protection but fail subsequent jobs or restore; this requires live provider read-back and a restore drill.

## Manual Gaps
- A reviewed live plan/apply, first successful backup-job read-back, and test restore remain required before production recovery can be claimed.
