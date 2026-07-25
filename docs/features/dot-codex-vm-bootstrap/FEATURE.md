# Dot Codex VM bootstrap

## Goal

A Mac operator can run one repository Bash entrypoint to bootstrap or repair the remote VM's `dot-codex` clone, Codex-home symlink, temporary SSH lifecycle, and Remote Control connection without discarding existing Codex state.

## Behavior

- `scripts/codex-vm.sh dot-codex` is the operator-facing clone-or-update workflow. It dispatches to its embedded dot-codex implementation, which reuses the bundled authoritative SSH and VM recovery helpers internally rather than duplicating their Azure and process-safety logic.
- Every phase prints a numbered step before it runs, important non-secret decisions while it runs, a success result after verification, or the exact phase that failed. Downstream command output remains visible.
- Before opening SSH, the command idempotently closes any retained or provider-side temporary SSH state. It then opens restricted SSH and always closes it on success, interruption, or failure.
- Before any Remote Control recovery or Codex-home change, the command checks the current managed Codex login over SSH. It then reconciles and runs the checked-in recovery helper through Azure Run Command.
- The default repository is `https://github.com/marcocello/dot-codex`, and the default remote clone is `~/projects/dot-codex` on the persistent managed disk. `DOT_CODEX_REMOTE_DIR` remains an explicit override for another absolute path.
- A missing clone is created. An existing clone is accepted only when it is a real Git worktree with the expected `origin` and no non-ignored worktree or index changes. After fetching, the helper uses Git's reflog-aware fork point to distinguish commits made after the branch's former tracked upstream from obsolete upstream history, then rebases only those VM-side commits onto the fetched `origin/*` ref.
- When a force-update replaced the tracked upstream and the branch has no commits after that former upstream tip, the empty reflog-aware rebase moves the branch directly to the rewritten origin without replaying superseded commits. Genuine VM-side commits after that tip are replayed and preserved.
- If the default rebase conflicts, the helper aborts the rebase, verifies that the original branch commit and clean worktree were restored, and fails before changing `~/.codex` or stopping the managed daemon.
- A `~/.codex` symlink that already resolves to the clone is left in place. Repeated successful runs do not create additional backups or restart the managed daemon solely to recreate the same link, but they still verify and repair Remote Control.
- When the existing Codex home contains the managed executable, the helper requires a successful Codex login-status check before stopping the daemon or moving `~/.codex`. Missing credentials direct the operator to launch `scripts/codex-vm.sh pair` from the Mac while leaving the existing Codex home and daemon untouched.
- Before replacing another `~/.codex`, the helper stops the managed Codex daemon when its provisioned executable exists, moves the old path to a unique timestamped backup, copies its non-Git contents into the clone, restores the clone's tracked files from Git, and creates the exact symlink.
- Remote Control repair first uses supported start/retry behavior, then invokes the reconciled VM recovery helper when needed, and finally requires machine-readable `connected` state with a non-empty environment identifier and no timeout. A merely running daemon, `connecting`, `errored`, or timed-out state is not success.
- If migration or Remote Control verification fails after the old path was moved, the helper removes only the link it created, restores the old `~/.codex`, attempts the same bounded recovery against the prior home, and returns failure.
- After SSH is closed, the Mac entrypoint performs one final Azure recovery pass. It reports the final clone, symlink, Remote Control, and SSH-closure outcomes without printing authentication material.

## External Contract

- `DOT_CODEX_REPOSITORY_URL` overrides the Git repository URL.
- `DOT_CODEX_REMOTE_DIR` overrides the remote clone path and must be absolute.
- `CODEX_VM_SSH_ALIAS` overrides the configured SSH alias.
- `DOT_CODEX_REMOTE_CONTROL_RETRY_SECONDS` overrides the bounded delay between Remote Control connection checks and must be an integer from 0 through 30.
- `DOT_CODEX_REMOTE_RECOVERY_HELPER` overrides the VM recovery-helper path for controlled testing; the production default is `/usr/local/sbin/ensure-codex-remote-control`.
- The command accepts no positional arguments.

## Constraints

- A mismatched existing clone, a non-Git target directory, a detached or non-tracking branch, or an ambiguous missing reflog-aware fork point fails before changing `~/.codex`. A conflicting VM-side replay is aborted and must restore the exact pre-rebase branch and clean worktree before failure.
- Existing VM-local ignored files, including the managed standalone executable and authentication state, retain their file metadata when migrated.
- The default workflow must never redirect `~/.codex` back to the VM OS disk; after migration both the clone and active Codex home resolve under `~/projects`.
- The migration never copies an old `.git` directory over the clone and never force-resets existing clone changes.
- Temporary SSH cleanup uses the repository's existing open and close helpers so their retained recovery-state behavior remains authoritative.
- Recovery attempts are bounded and preserve authentication, pairing, settings, repositories, and unrelated processes.

## Non-Goals

- Installing Git, configuring GitHub credentials, or changing the repository's visibility.
- Running the bootstrap automatically during Terraform apply or cloud-init.
- Proving live Azure networking, GitHub authentication, or paired Remote Control behavior in the local proof.
