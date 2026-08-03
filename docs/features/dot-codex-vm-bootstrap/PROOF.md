# Proof

## Done

- The extracted production helper fails at a bounded VPN reachability probe when the private alias is unavailable.
- With VPN reachability, it creates and updates a real persistent Git clone, preserves runtime state, creates the exact Codex-home symlink, and avoids duplicate migration on rerun.
- Real Git fixtures prove force-update convergence, preservation of one VM-only commit, dirty-worktree refusal, and conflict rollback.
- Missing authentication fails before daemon or Codex-home mutation.
- Deterministic Remote Control responses prove rejection of connecting, timed-out, and missing-environment states before a valid connected result.
- Post-migration recovery failure restores the original Codex home.
- Lifecycle logs contain no public SSH open/close operation.

## Command

```bash
"${CODEX_HOME:-$HOME/.codex}/scripts/proof_run_capture" --feature-dir docs/features/dot-codex-vm-bootstrap --timeout-seconds 60 --note "exercise VPN-only dot-codex bootstrap, Git convergence, connection read-back, and rollback"
```

## Boundaries

Real Bash, Git, filesystem migration, symlinks, rebase, and rollback execute in temporary fixtures. Network SSH, Azure recovery transport, and managed Codex responses are deterministic fakes. Live Azure, GitHub credentials, and paired-device relay behavior remain outside this proof.
