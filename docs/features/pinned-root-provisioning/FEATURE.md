# Pinned Root Provisioning

## Summary
Ensure VM provisioning never executes or installs mutable direct-download content as root without a repository-reviewed version and integrity check.

## Desired Behavior
- The Ubuntu marketplace image uses an explicit published version instead of `latest`.
- Codex is installed by the VM provisioner embedded in `scripts/codex-vm.sh` and launched from the local machine through Azure Run Command. Its explicit release URL, version, target, and SHA-256 digest are declared in Terraform-owned configuration and passed through non-sensitive Terraform outputs.
- The downloaded Codex archive is verified before extraction, installed atomically into the standalone layout, and its reported version is checked before the bootstrap readiness marker is created.
- Any digest or version mismatch stops provisioning without publishing the mismatched executable through `/usr/local/bin`.

## Constraints
- No remote script is piped into a shell or executed directly from a mutable URL.
- Terraform and cloud-init do not execute the installer. The local preparation entrypoint extracts the checked-in inline payloads, verifies their checksums on the VM, and then invokes the installer in the Azure Run Command root context.
- Direct artifact URLs must use HTTPS, and the expected digest must be a literal 64-character SHA-256 value reviewed in this repository.
- Ubuntu packages and unattended security updates continue to use signed apt repositories; this feature pins direct provisioning artifacts without disabling security patching.
- Updating Codex or the base image requires an explicit code change with refreshed version and digest evidence.
- No live VM replacement or Azure apply is part of this local implementation pass.

## Implementation Routing
- Required skills: coding-feature-execute, coding-proof-author, openai-docs
