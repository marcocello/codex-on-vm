# Dot Codex VM bootstrap

## Goal

A Mac operator can bootstrap or repair the VM's persistent `dot-codex` clone, Codex-home symlink, and Remote Control connection through the already connected OpenVPN tunnel.

## Behavior

- `scripts/codex-vm.sh dot-codex` requires `codex-on-vm-vpn` to be reachable before any remote action.
- The workflow never creates, deletes, or inspects an Azure TCP/22 rule and has no public SSH fallback.
- The default clone is `~/projects/dot-codex` on the persistent managed disk. `DOT_CODEX_REMOTE_DIR` may override it with another absolute path.
- A missing clone is created. An existing clone must be a clean, real Git worktree with the expected origin and a tracking branch.
- Fetch and reflog-aware rebase preserve genuine VM-only commits across an upstream force-update. Rebase conflicts abort and restore the original clean branch before Codex-home mutation.
- Existing ignored Codex state is migrated without overwriting Git-owned files. The prior Codex home is retained as a timestamped backup and `~/.codex` becomes the exact symlink.
- Missing Codex login fails before daemon or home mutation and directs the operator to the Mac `sign-in` command.
- Remote Control recovery is bounded and accepts only a connected, non-timed-out result with an environment identity.
- A failed post-migration recovery restores the previous Codex home.
- Progress is reported in six phases: validation, VPN reachability, pre-migration recovery, bootstrap, final recovery, and completion.

## External contract

- `CODEX_VM_VPN_SSH_ALIAS` overrides the private SSH alias.
- `DOT_CODEX_REPOSITORY_URL`, `DOT_CODEX_REMOTE_DIR`, `DOT_CODEX_REMOTE_CONTROL_RETRY_SECONDS`, and `DOT_CODEX_REMOTE_RECOVERY_HELPER` retain their bounded overrides.
- The command accepts no positional arguments.

## Non-goals

- Public SSH bootstrap, SSHFS mounting, GitHub credential setup, Terraform execution, or live Azure network mutation.
