# Remote Control managed workspace

## Goal

Provision and recover a persistent Codex workspace through Azure Run Command, use Remote Control as the normal product path, and allow direct development only through OpenVPN plus VS Code Remote-SSH.

## Behavior

- Terraform creates infrastructure, a protected managed workspace disk, one UDP/1194 OpenVPN ingress rule, and non-secret connection outputs. It does not run guest setup.
- `scripts/codex-vm.sh setup` sends checksummed preparation payloads through Azure Run Command, mounts the managed disk, installs the pinned Codex CLI, configures reboot recovery, restores OpenVPN server material, and reads back readiness plus the SSH host key.
- Setup writes one strict Mac SSH host, `codex-on-vm-vpn`, at private address `10.250.0.1`. It preserves the Ed25519 client key and dedicated known-hosts file required by VS Code Remote-SSH.
- Codex state and repositories live under `/home/azureadmin/projects` and survive VM replacement.
- Sign-in and pairing are separate Mac actions through the connected VPN. Remote Control is the normal ongoing path and uses outbound connectivity.
- Systemd boot and timer units reconcile Remote Control without exposing the app server.
- Azure Run Command remains the setup and recovery path when the VPN or Remote Control is unavailable.
- There is no public TCP/22 rule, temporary SSH lifecycle, SSHFS mount workflow, or mobile SSH key.

## Storage decision

A 256 GiB Standard SSD managed disk with ext4 owns the live repositories and Codex state. VS Code Remote-SSH keeps Git, language servers, dependencies, and builds on that native Linux filesystem.

## Constraints

- Existing workspace data is never formatted or discarded during idempotent setup.
- SSH rejects passwords and root, permits only the generated Mac key, and is reachable only inside OpenVPN.
- Preparation, recovery, and health checks are bounded and do not print secrets.
- Terraform state never contains Codex credentials, pairing codes, VPN private keys, or the Mac SSH private key.

## Non-goals

- Public SSH recovery, repository-managed local mounts, Azure Files migration, managed VPN Gateway, or multi-user VPN service.
