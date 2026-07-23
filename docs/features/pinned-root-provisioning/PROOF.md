# Proof Plan

## Definition Of Done
- A mocked root Terraform plan renders the exact pinned image and Codex release.
- The rendered cloud-init contains repository-owned verified-download/install scripts and contains no mutable Codex install-script execution.
- The production Codex installer publishes a valid package only after matching its expected digest and version.
- A tampered archive is rejected and leaves no published executable or release directory.

## Primary Proof
Type: cli-subprocess

Boundary:
- Producer: Terraform renders VM cloud-init and cloud-init invokes repository-owned provisioning commands as root.
- Activation path: `terraform test` plans the real root module, and the proof invokes the exact production artifact installer as a subprocess.
- Consumer: Terraform image/custom-data configuration plus the verified fetch and Codex package installer scripts.
- Durable state: Mocked VM plan and temporary standalone release/bin directories.
- Read-back: Terraform assertions, installed command version, symlink target, release layout, and absence of files after an injected digest mismatch.
- Unsafe edge: Azure provider calls and remote downloads are replaced by Terraform mocks and a fake `curl` executable serving local fixtures.

Command:
```bash
scripts/proof_run_capture --serious --feature-dir docs/features/pinned-root-provisioning --source-path deployment/prod/tf/main.tf --source-path deployment/prod/tf/vm.tf --source-path deployment/prod/tf/templates/cloud-init.yaml --source-path deployment/prod/tf/scripts/fetch-verified-artifact.sh --source-path deployment/prod/tf/scripts/install-verified-codex.sh --source-path deployment/prod/tf/tests/pinned_root_provisioning.tftest.hcl --source-path docs/features/pinned-root-provisioning/proof/run.sh --behavior-boundary "Terraform root plan and cloud-init -> repository-owned verified installers -> planned pins and installed-or-rejected artifact read-back" --oracle-scope "$(cat docs/features/pinned-root-provisioning/PROOF.md)" --notes "Provisioning pins root-installed artifacts and rejects tampered Codex packages before publication" -- docs/features/pinned-root-provisioning/proof/run.sh
```

Expected evidence:
- Terraform test reports the pinned root-provisioning plan passed.
- The valid fixture installs as version `0.144.3` in the standalone layout.
- The package is executable from the daemon-required `packages/standalone/current/codex` path.
- The modified fixture fails SHA-256 validation and creates no visible command.

## Claimed Behavior Coverage
| FEATURE claim | Real production entrypoint proof drives | Fake boundary used | Read-back |
| --- | --- | --- | --- |
| Root Terraform plan uses explicit image and artifact pins | Root `terraform test` plan | Provider operations | Planned image version and rendered cloud-init text |
| Verified Codex package installs atomically | Production installer subprocess | Remote bytes served by fake `curl` | Release layout, symlink, and `codex --version` |
| Tampered Codex package fails closed | Same production installer with changed bytes | Remote bytes served by fake `curl` | Nonzero result and absence of release/bin paths |

## Fake Boundary Ledger
- Fake: AzureRM, External, and Local provider calls plus remote HTTP transport.
- Allowed because: The proof must not replace a paid VM or install packages on a live root filesystem.
- Not faked: Terraform parsing/planning, cloud-init rendering, production verified-download and installer scripts, SHA-256 calculation, archive extraction, version check, atomic publication, and filesystem read-back.

## Proof Scope
Proves:
- The local Terraform and provisioning implementation declares fixed inputs and fails closed for a tampered Codex archive at the real installer boundary.

Does not prove:
- Azure marketplace image availability at apply time, live cloud-init completion, future release availability, or runtime compatibility of the real binary on the deployed VM.

False-green risks:
- A legitimate upstream artifact could later disappear despite remaining cryptographically pinned.
- A compromised repository commit could maliciously update both URL and digest; code review and repository controls remain required.

Evidence strength:
- deterministic configuration and installer proof with live-VM gap

## Secondary Guards
- `terraform fmt -check -recursive`
- `terraform validate`
- `bash -n deployment/prod/tf/scripts/fetch-verified-artifact.sh deployment/prod/tf/scripts/install-verified-codex.sh`
- `git diff --check`

## Environment And Data
- Terraform 1.14+, initialized providers, Bash, tar, Python 3, and SHA-256 tooling.
- Generated local archives and fake HTTP transport only; no Azure credentials or root writes.

## Anti-Gaming Review
- Fake pass risk: declare a version but still download `latest`. Proof catch: Terraform assertions require the exact versioned release URL and reject the mutable installer URL.
- Fake pass risk: calculate a digest after download without comparing to a repository pin. Proof catch: a tampered fixture must fail and leave no visible command.
- Fake pass risk: verify bytes but publish before checking package version. Proof catch: the installed command must report the declared version before atomic publication succeeds.
- Fake pass risk: pin Codex while leaving the base image mutable. Proof catch: the rendered plan asserts the exact image version.
- Broken implementation that would still pass: a malicious reviewed commit could change both bytes and expected digest; repository review/signing is outside the VM provisioning boundary.

## Manual Gaps
- A reviewed live plan/apply and cloud-init status/log read-back remain required before the deployed VM can be claimed to use these pins.
