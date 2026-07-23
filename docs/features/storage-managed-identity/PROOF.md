# Proof Plan

> Superseded by `docs/features/remote-control-managed-workspace`. This proof is retained as historical evidence only.

## Definition Of Done
- A mocked Terraform plan renders a VM using a user-assigned identity and managed-identity SMB mount configuration.
- The plan enables SMB OAuth and assigns `Storage File Data SMB MI Admin` without assigning storage key-operator permissions.
- Rendered cloud-init uses `azfilesauthmanager`, Kerberos, and automatic refresh without a storage-key request or credential file.

## Primary Proof
Type: static-doc

Boundary:
- Producer: Terraform configuration and the Ubuntu cloud-init template.
- Activation path: `terraform test` creates a provider-mocked plan through the real Terraform module entrypoint.
- Consumer: Terraform provider schemas, template rendering, dependency graph, and native test assertions.
- Durable state: captured Terraform test plan and assertions in the evidence bundle.
- Read-back: Terraform test output plus rendered planned VM and RBAC attributes.
- Unsafe edge: Azure control-plane and VM provisioning calls are replaced by Terraform mock providers.

Command:
```bash
scripts/proof_run_capture --serious --feature-dir docs/features/storage-managed-identity --source-path deployment/prod/tf/providers.tf --source-path deployment/prod/tf/storage.tf --source-path deployment/prod/tf/vm.tf --source-path deployment/prod/tf/templates/cloud-init.yaml --source-path deployment/prod/tf/tests/managed_identity_storage.tftest.hcl --source-path docs/features/storage-managed-identity/proof/run.sh --behavior-boundary "Terraform configuration -> mocked provider plan -> rendered VM identity and SMB mount assertions" --oracle-scope "$(cat docs/features/storage-managed-identity/PROOF.md)" --notes "Managed-identity SMB plan removes VM storage-account key access" -- docs/features/storage-managed-identity/proof/run.sh
```

Expected evidence:
- Terraform test reports the managed-identity storage run as passed.
- No production Terraform or rendered cloud-init contains key-listing or VM credential-file behavior.

## Claimed Behavior Coverage
| FEATURE claim | Real production entrypoint proof drives | Fake boundary used | Read-back |
| --- | --- | --- | --- |
| VM uses a user-assigned identity | Root Terraform plan | AzureRM mock provider | Planned VM identity block and identity resource |
| Storage supports SMB OAuth | Root Terraform plan | AzAPI mock provider | Planned `isSmbOAuthEnabled` property |
| VM cannot list storage keys | Root Terraform plan and cloud-init rendering | Azure calls omitted | Planned RBAC role and negative key-path guard |
| Workspace mounts with OAuth/Kerberos | Root Terraform plan and template rendering | VM boot omitted | Decoded `custom_data` assertions |

## Fake Boundary Ledger
- Fake: AzureRM, AzureAD, External, Local, and AzAPI provider network operations.
- Allowed because: live apply can replace the VM and mutate paid Azure resources, which is outside this pass.
- Not faked: Terraform parsing, provider schemas, module planning, template rendering, configured role names, identity wiring, and mount options.

## Proof Scope
Proves:
- The locally rendered infrastructure graph removes VM storage-key retrieval and configures the documented SMB OAuth client path.

Does not prove:
- Azure preview availability in the subscription, RBAC propagation, package download, live VM boot, SMB mount success, credential refresh, or preservation of existing data after apply.

False-green risks:
- Azure may reject the preview property or role in the target subscription even though the provider-mocked plan is valid.
- The `azfilesauth` package or service behavior can change independently of this Terraform configuration.

Evidence strength:
- deterministic local configuration proof with a live Azure gap

## Secondary Guards
- `terraform fmt -check -recursive`
- `terraform validate`
- Shell syntax checks for repository scripts

## Environment And Data
- Terraform 1.14+ and initialized provider plugins.
- No Azure credentials or live resources are used by the primary proof.

## Anti-Gaming Review
- Fake pass risk: adding the managed identity while leaving the Key Operator assignment in place.
- Proof catch: the run script rejects key-operator and `listKeys` behavior in production Terraform, while the plan asserts the replacement role.
- Fake pass risk: configuring OAuth on storage but continuing to write an account key to the VM.
- Proof catch: decoded planned cloud-init must contain Kerberos and `azfilesauthmanager` and must not contain the credential file or key API.
- Fake pass risk: creating an identity that is not attached to the VM.
- Proof catch: the planned VM identity block must reference the dedicated identity.
- Broken implementation that would still pass: Azure can reject or fail the preview behavior at live apply; this remains an explicit live gap rather than a local completion claim.

## Manual Gaps
- A reviewed live `terraform plan` and approved `terraform apply`, followed by VM reboot/remount and Azure role read-back, remain required before production completion.

## Proof Change Guard
- Original issue: the initial mocked SSH public-key strings were not valid Ed25519 wire-format keys, so AzureRM rejected the fixture before planning the feature.
- Second fixture issue: the mocked identity ID and client ID remained apply-time unknown during `command = plan`, making identity wiring and rendered cloud-init assertions undecidable; deterministic plan-time override values were added.
- Green-but-broken repair: upstream `azfilesauth` drops to `azfilesuser` before rereading `config.yaml`; the original root-only `0600` file made live authentication permission-dependent. The proof now requires root ownership, the helper group, and mode `0640`.
- Live mount repair: the storage file service allowed only `NTLMv2`, so a valid managed-identity Kerberos ticket still failed SMB session setup with `STATUS_LOGON_FAILURE`. The proof now requires both `Kerberos` for the VM and `NTLMv2` for the separately preserved Mac storage-key workflow.
- Client compatibility repair: package `1.0-11` ships the non-secret config as `root:root` mode `0644`, and the live library emitted config-read warnings while ignoring the custom `KRB5_CC_NAME` path after dropping privileges. The proof now requires the package-compatible ownership and mode, preserves only the credential UID, and leaves credential-cache placement to the supported client.
- Fake implementation caught: unchanged; the proof still rejects a VM that retains Key Operator access, key retrieval, or credential-file mounting.
- Red evidence: initial fixture failures were followed by a green plan; the strengthened permission assertion then failed against the root-only configuration, and the live Kerberos authentication assertions fail against the current NTLMv2-only service and custom cache override before implementation repair.
- Green evidence: recorded by the next captured run after fixture and configuration-permission repair.
- Scope: behavior and assertions were not reduced; only provider-invalid fixture data changed.
