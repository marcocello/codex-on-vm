# VPN-only Codex VM access

## Goal

A Mac operator uses Remote Control for ordinary Codex operation and an already connected OpenVPN client for every interactive VM session. VS Code Remote-SSH, direct terminal SSH, account actions, dot-codex maintenance, and VPN trust maintenance never open public TCP/22.

## Behavior

- Terraform creates exactly one standing operator-ingress rule: UDP/1194 named `AllowOpenVpn` on the existing VM NSG. It creates no TCP/22 rule, temporary-SSH metadata, VPN Gateway, Bastion, second VM, paid security plan, cloud-init payload, or secret output.
- `scripts/codex-vm.sh setup` remains the no-SSH preparation and repair path. It uses Azure Run Command, restores persistent OpenVPN server material after the managed disk is mounted, and writes a single strict Mac SSH alias named `codex-on-vm-vpn`.
- The Mac SSH configuration contains no public `codex-on-vm` alias. The VPN alias targets `10.250.0.1`, reuses the VM's pinned public host identity through `HostKeyAlias`, and retains key-only authentication plus strict host-key checking.
- `sign-in`, `pair`, `dot-codex`, and `vpn-setup` require `codex-on-vm-vpn` to be reachable. If the OpenVPN client is disconnected, they fail with visible import/connect guidance and perform no Azure ingress mutation.
- `vpn-setup` repairs the server only from a complete existing Mac trust set. If that trust is missing or partial, ordinary repair fails before local credential generation or remote mutation and explains that the operator must restore it. `vpn-setup --rotate` is the only command that intentionally generates replacement trust, over the already connected VPN alias. Neither path uses a public SSH alias or an Azure NSG mutation.
- A repeated `vpn-setup` preserves credentials. Rotation remains transactional, preserves a private local recovery backup, rolls back a confirmed service failure, and reconciles a lost SSH result by comparing the remote CA fingerprint.
- The OpenVPN client profile remains single-Mac, mutual-certificate, `tls-crypt`, TLS 1.2+, modern AEAD, and split-tunnel for only `10.250.0.0/24`; it does not redirect the Mac default route, push DNS, enable compression, bridge Ethernet, forward to the VNet, or permit client-to-client traffic.
- Server credentials persist under a root-only directory on the managed projects disk and are copied to `/etc/openvpn/server` for the native Ubuntu service. The CA private key and client private material remain only on the Mac.
- The console exposes no repository-managed shell, status, `ssh-open`, `ssh-close`, `workspace-open`, or `workspace-close` commands and materializes no corresponding helpers. VS Code Remote-SSH or direct `ssh codex-on-vm-vpn` opens the VM; repository-managed SSHFS mounting is removed.

## External Contract

```text
scripts/codex-vm.sh setup
scripts/codex-vm.sh sign-in
scripts/codex-vm.sh pair
scripts/codex-vm.sh dot-codex
scripts/codex-vm.sh vpn-setup [--rotate]
ssh codex-on-vm-vpn
```

- The local OpenVPN root defaults to `~/.config/codex-on-vm/openvpn` with mode 0700.
- The importable profile defaults to `~/.config/codex-on-vm/openvpn/codex-on-vm.ovpn` with mode 0600.
- The VPN server address is `10.250.0.1` in `10.250.0.0/24` over public UDP/1194.
- The Mac Ed25519 key and dedicated known-hosts file remain required for SSH inside the VPN.

## Constraints

- Private keys, inline profiles, `tls-crypt` material, and certificate contents never enter Git, Terraform state or output, Azure Run Command payloads, console output, or retained proof artifacts.
- Public TCP/22 must remain closed even when the VPN is unavailable; there is no automatic or manual repository fallback.
- OpenSSH server and client support remain because VS Code Remote-SSH requires them, but they are reachable only through the OpenVPN tunnel.
- Terraform stays manual and infrastructure-only. Azure Run Command remains the non-interactive setup and Remote Control recovery path.
- The repository keeps `scripts/codex-vm.sh` as its only production shell script; retained helpers and VM payloads are embedded and privately materialized.

## Non-Goals

- Installing, launching, connecting, or disconnecting the macOS OpenVPN GUI.
- Supporting first-time VPN trust bootstrap after loss of both the managed-disk server state and the Mac credential directory. Restoring those backups is an operator recovery task.
- Supporting multiple clients, full-tunnel browsing, site-to-site routing, other VNet resources, SSHFS, a public SSH fallback, or mobile SSH keys.
- Removing the VM public IP, which remains the OpenVPN endpoint and outbound path.
- Proving a live Azure apply, UDP transport, macOS tunnel handshake, or VS Code UI behavior in local proof.

## Required Skills

- coding-feature-execute
- coding-proof-author
