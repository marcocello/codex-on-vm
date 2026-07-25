# Proof

## Done

- The production Mac helper creates and updates a real Git clone under the remote fixture's persistent `projects` directory when no override is supplied.
- A clean branch at its former tracked upstream tip follows a force-updated origin without replaying obsolete upstream commits; a later genuine local commit is the only commit replayed across another force-update.
- A conflicting default rebase aborts, restores the exact original branch commit and clean worktree, and fails before daemon or Codex-home mutation.
- A real Codex directory becomes a timestamped backup, its ignored runtime state survives in the clone, tracked repository files win, and `.codex` resolves to `dot-codex`.
- A second run updates the clone without creating another backup or repeating the daemon migration.
- An existing clone with tracked local edits is rejected before the daemon or `.codex` changes.
- A managed but unauthenticated Codex home is rejected before the daemon or `.codex` changes and directs the operator to the Mac-owned `scripts/codex-vm.sh pair` workflow rather than VM-side authentication.
- A stale prior SSH state is normalized before opening, every phase is printed in order, and Azure recovery runs before migration and after SSH closure.
- Remote Control progresses through `connecting` with otherwise valid fields, failed starts, the VM recovery helper, `connected` with a timeout, `connected` with an empty environment ID, and finally verified `connected` state; daemon-only health and every independently invalid status, timeout, or environment response are insufficient.
- Remote failure closes temporary SSH, and a post-move recovery failure restores the original Codex directory.

## Command

```bash
"${CODEX_HOME:-$HOME/.codex}/scripts/proof_run_capture" --feature-dir docs/features/dot-codex-vm-bootstrap --timeout-seconds 60 --note "exercise single-entrypoint bootstrap, repair, step output, idempotency, and rollback boundaries"
```

## Scenario: Fresh migration and idempotent update

- Producer/activation: the proof extracts the production bundle from `scripts/codex-vm.sh`, invokes an exact copy of its dot-codex helper with the default empty remote-path override, then repeats the workflow after the origin advances.
- Consumer: the production entrypoint normalizes stale SSH state, opens temporary SSH, reconciles Azure recovery, transmits its real remote program through an `ssh` subprocess, closes SSH, and performs final Azure recovery.
- Read-back: the proof uses real Git and filesystem tools to inspect the default `~/projects/dot-codex` clone path, origin and revision, tracked content, migrated ignored files, backup count, exact `~/.codex` symlink into `projects`, daemon/recovery command logs, lifecycle ordering, and numbered operator output after the first and second runs.
- Fake: only Azure-backed SSH open/close, Azure recovery transport, the network SSH transport, and the managed Codex/recovery executables are replaced. The fake SSH executable reparses the remote command with an OpenSSH-equivalent shell boundary; Git clone, fetch, merge, backup, migration, rollback, and symlink behavior remain real.
- Catches: a helper that merely prints commands, hides phase progress, defaults back to VM-local `~/dot-codex`, replaces the wrong host path, loses runtime state, overwrites tracked clone content, recreates backups on rerun, skips updates, restarts unnecessarily, leaves SSH open, or requires multiple operator commands.

## Scenario: Remote Control needs real repair and connection read-back

- Producer/activation: the managed Codex fake first reports `connecting` with no timeout and a valid environment ID, rejects subsequent starts until the reconciled VM recovery helper runs, then independently reports `connected` with a timeout and `connected` with an empty environment ID before reporting a valid connected response.
- Consumer: the production remote repair loop and VM recovery-helper boundary run unchanged.
- Read-back: ordered subprocess logs require rejection of independently invalid status, timeout, and environment responses, failed starts, one VM recovery invocation, and final valid `connected` output; the operator log must distinguish repair from verified connection.
- Fake: the Codex executable and VM recovery helper expose deterministic state through runtime files and JSON output.
- Catches: treating process health, recovery-helper exit zero, a non-connected response with otherwise valid fields, a timed-out connected response, or a connected response with a missing environment ID as Remote Control success.

## Scenario: Existing tracked work is preserved

- Producer/activation: the fixture creates the expected clone, modifies a tracked file locally, retains a real `.codex` directory, and invokes the production helper.
- Consumer: the production helper inspects the same Git worktree it would otherwise update and migrate.
- Read-back: the command must fail, temporary SSH must close, the tracked edit must remain byte-for-byte, and `.codex` must remain the original directory with no backup created.
- Fake: only the unsafe SSH lifecycle and transport remain fake.
- Catches: using `git restore`, checkout, reset, or migration overlay to erase pre-existing tracked clone work.

## Scenario: Reflog-aware force-update convergence

- Producer/activation: after a successful update, the real remote clone remains exactly at the former tracked upstream while the bare origin is force-updated from their common base with a conflicting replacement. After the first convergence, the clone receives one genuine local commit and origin is force-updated again from the common base.
- Consumer: the production helper fetches each rewritten tracking ref, derives the real reflog-aware fork point, and runs its default Git convergence behavior unchanged.
- Read-back: the first pass must move directly to the rewritten origin with no replayed commits or obsolete bytes. The second must produce exactly the one genuine local commit above the next rewritten origin, with the expected subject, no merge commit, neither prior tip in ancestry, both rewritten-origin and local bytes present, no additional Codex backup, and no repeated daemon migration.
- Fake: only the unsafe Azure and SSH boundaries plus managed Codex executable remain deterministic fakes; Git fetch, forced ref update, rebase, commit replay, and ancestry inspection are real.
- Catches: retaining the prior fast-forward-only refusal, naively replaying the entire merge-base range, unconditionally resetting genuine local commits, merging instead of rebasing, or recreating the Codex home after a history-only repair.

## Scenario: Conflicting rebase restores the original branch

- Producer/activation: a separate real clone and origin make conflicting clean commits to the same tracked file, then invoke the production helper.
- Consumer: the production helper reaches the same default rebase boundary used for a live diverged checkout.
- Read-back: the command must fail with the aborted-rebase explanation, SSH must close, `HEAD` and tracked bytes must equal the pre-run local commit, no rebase metadata or worktree changes may remain, `.codex` must remain the original directory, and no daemon stop or Remote Control start may run.
- Fake: only the unsafe Azure and SSH boundaries plus managed Codex executable remain deterministic fakes.
- Catches: leaving a conflicted checkout, discarding local commits, continuing into migration after rebase failure, or silently merging divergent histories.

## Scenario: Missing Codex credentials fail before migration

- Producer/activation: the fixture provides a managed Codex executable whose real `login status` subprocess boundary reports no login, then invokes the production helper.
- Consumer: the production helper reaches the same managed executable it would stop and migrate.
- Read-back: the command must fail with the local `scripts/codex-vm.sh pair` instruction and no “on the VM” direction, temporary SSH must close, `.codex` must remain the original directory, no backup may exist, and neither Azure recovery, daemon stop, nor Remote Control start may run.
- Fake: the unsafe SSH lifecycle and transport plus the managed Codex executable are deterministic subprocess fakes.
- Catches: discovering missing credentials only after moving the Codex home or disrupting the daemon.

## Scenario: Failure cleanup and rollback

- Producer/activation: one fixture makes the SSH transport fail after access opens; another uses an override containing spaces and shell metacharacters, then makes every Remote Control attempt and the VM recovery helper fail.
- Consumer: the same production helper and transmitted remote program execute unchanged.
- Read-back: the lifecycle log must end in SSH close for both failures, while the restart fixture must prove that the exact override was cloned and reached the managed restart before leaving the original `.codex` directory restored rather than the new symlink.
- Fake: the unsafe transport and managed Codex executable are deterministic fakes at their subprocess boundaries.
- Catches: missing outer cleanup, destructive partial migration, or a success result after Remote Control restart failed.

## Scope

Proves:

- Single-entrypoint Mac orchestration, persistent default clone placement, numbered progress output, stale SSH normalization, Azure recovery ordering, remote Git convergence through default rebase, rebase-conflict restoration, tracked-work and missing-login refusal, state-preserving symlink migration, actual Remote Control connection read-back, repeat-run behavior, cleanup, and rollback across production subprocess boundaries.

## Repair History

- 2026-07-24 evaluator correction: missing-login failures still printed a direct `codex login --device-auth` or “authenticate on the VM” instruction after deployment ownership moved to Mac-launched entrypoints. The proof now requires `scripts/codex-vm.sh pair` guidance and rejects VM-side authentication instructions.
- 2026-07-23 persistence correction: the default clone must live at `~/projects/dot-codex` so the operator bootstrap cannot redirect the active `~/.codex` back to the VM OS disk after the local preparation entrypoint established a persistent home.
- Strengthened proof decision: drive the production helper with an empty `DOT_CODEX_REMOTE_DIR`, precreate the remote `projects` mount fixture, and require both the real clone and `~/.codex` read-back to resolve under that persistent directory. Explicit override scenarios remain unchanged.
- Red evidence: captured attempt `proof/runs/20260723T220030820730Z` runs the pre-change default, logs `Remote clone: $HOME/dot-codex`, creates the real clone in the VM-local home, and fails because the expected persistent clone was not created.

Does not prove:

- Live Azure NSG changes, SSH authentication, GitHub credentials, network availability, or successful paired-device reconnection.

False-green risks:

- The temporary VM fixture cannot reproduce every live Codex runtime file type or a provider-side SSH cleanup failure.
- A future Git or Codex CLI version could change command behavior after this deterministic local run.

Evidence method:

- deterministic

Known gaps:

- live
- provider

## Environment

- macOS behavior is selected with a fake `uname`; Bash and Git execute locally against temporary directories with no credentials or network.
- Runner stdout: resolved Bash and Git executable paths and versions, production helper path, and temporary remote-home readiness.
