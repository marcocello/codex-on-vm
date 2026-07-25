# Proof Plan

## Definition Of Done
- A mocked Terraform plan exposes the exact pinned Ubuntu image and Codex release URL, version, and SHA-256 digest without launching guest preparation.
- The checked-in local preparation and VM provisioner paths use the repository-owned verified fetch/install scripts and contain no mutable Codex install-script execution.
- The production Codex installer publishes a valid package only after matching its expected digest and version.
- A tampered archive is rejected and leaves no published executable or release directory.

## Primary Proof
Type: CLI subprocess

Boundary:
- Producer: Terraform outputs the reviewed pins and the local preparation entrypoint transmits the provisioner/installers extracted from `scripts/codex-vm.sh`.
- Activation: `terraform test` plans the production root, and the proof invokes the exact production artifact installer as a subprocess.
- Consumer: Terraform image/output configuration plus the verified fetch and Codex package installer scripts consumed by local VM preparation.
- Durable state: Mocked VM plan and temporary standalone release/bin directories.
- Read-back: Terraform assertions, source ownership guards, installed command version, symlink target, release layout, and absence of files after an injected digest mismatch.
- Unsafe edge: Azure provider calls and remote downloads are replaced by Terraform mocks and a fake `curl` executable serving local fixtures.

Command:
```bash
"${CODEX_HOME:-$HOME/.codex}/scripts/proof_run_capture" --feature-dir docs/features/pinned-root-provisioning --timeout-seconds 30 --note "Verify locally launched VM preparation retains pinned root artifact installation"
```

Expected evidence:
- Terraform test reports the pinned root-provisioning plan passed with an explicit image and non-sensitive Codex output pins.
- Terraform has no custom-data bootstrap, while the local and VM preparation scripts reference the checked-in verified installer boundary.
- The valid fixture installs as version `0.144.3` in the standalone layout.
- The package is executable from `packages/standalone/current/codex`.
- The modified fixture fails SHA-256 validation and creates no visible command.

## Scope
Proves:
- The repository declares fixed VM/package inputs and fails closed for a tampered Codex archive at the real installer boundary after deployment ownership moves to the local entrypoint.

Does not prove:
- Azure marketplace image availability, live Run Command transport, future release availability, or runtime compatibility of the real binary on the deployed VM.

False-green risks:
- A legitimate upstream artifact can disappear while remaining cryptographically pinned.
- A compromised repository commit could maliciously update both URL and digest.

Evidence method:
- Deterministic Terraform and real installer subprocess proof.

Known gaps:
- Live Azure and upstream artifact availability.

## Secondary Guards
- `terraform fmt -check -recursive`
- `terraform validate`
- `bash -n` for fetch, installer, local preparation, and VM provisioner scripts
- `git diff --check`

## Environment
- Terraform 1.14+, Bash, tar, Python 3, and SHA-256 tooling.
- Generated archives and fake HTTPS transport only; no Azure credentials or root writes.

## Proof Repair History
- 2026-07-24 deployment-ownership correction: the verified installer is no longer activated by cloud-init. Terraform exposes the reviewed pins, the machine-preparation helper embedded in `scripts/codex-vm.sh` transmits checksummed checked-in code, and the VM provisioner invokes the same installer from Azure Run Command's root context. The archive-integrity and atomic-publication proof remains unchanged.

## Manual Gaps
- A reviewed live plan, local preparation run, and installed-version read-back are required before claiming the deployed VM uses the pin.
