# Completion

Proof: PASS — a pseudo-terminal delayed the production Azure preparation check for option 2 and observed the Terraform target read, Azure subscription check, VM marker activation, and periodic elapsed-time output before completion. Existing exact menu, VPN preflight, action visibility, terminal preservation, and explicit-only OpenVPN rotation scenarios also passed.

Gate: PASS — `${CODEX_HOME:-$HOME/.codex}/scripts/gate --root "$PWD"` passed common, other, and Git diff checks.

Evaluator:
Evaluator: FAIL
Intent: Visibility repair aligns with the user’s requested preparation progress behavior.
Behavior: Target and elapsed-time output now appear correctly, but the progress worker leaves subprocesses behind.
Architecture: The background subshell is killed while its active `sleep` child survives, weakening process-lifecycle ownership.
Proof realism: PTY coverage validates visibility and prior behavior, but the final result records cleanup `terminated` with `term_sent: true`.
False-green risk: Blocking; the runner reports PASS only because capture cleanup terminates leaked processes.
Known gaps: Blocking — subprocess cleanup is a required behavior.
Gate: PASS — canonical gate passed.
Next: Reap the complete progress worker process tree, prove capture cleanup is `clear`, and rerun evaluation.

Correction or repair context:
Azure Run Command JSON is intentionally captured and invoked with `--only-show-errors`, which previously left only the stage heading visible during a long preparation check. The repair prints each boundary before invoking it and emits a new progress line every ten seconds while Azure remains pending. The retained red attempt is `../20260803T104733687859Z`.

Queue invalidation: not applicable because this repository has no `docs/features/status.json`.
