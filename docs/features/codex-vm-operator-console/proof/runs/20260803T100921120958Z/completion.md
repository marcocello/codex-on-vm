# Completion

Gate: PASS — `${CODEX_HOME:-$HOME/.codex}/scripts/gate --root "$PWD"` passed common, other, and Git diff checks.

Evaluator:
Evaluator: FAIL
Intent: Contract matches the corrected options 1–5, one-shot menu, visible checks/output, setup recovery exception, and explicit-only trust rotation.
Behavior: `vpn-setup` violates the contract: when local OpenVPN trust is absent, `openvpn-setup.sh` generates new credentials without `--rotate`, silently replacing trust instead of requiring existing trust.
Architecture: Menu, dispatcher, centralized preflights, and VPN-only access preserve the owning boundaries; the implicit rotation is a safety-boundary violation.
Proof realism: PTY/menu, mappings, output visibility, disconnected preflight, and terminal-clear checks are realistic, but option 5 uses a fake helper and never verifies ordinary repair rejects missing trust.
False-green risk: Blocking; the current centrally incorrect trust behavior passes.
Known gaps: Blocking — ordinary `vpn-setup` must fail when existing Mac trust is unavailable; only `--rotate` may generate replacement trust.
Gate: PASS — canonical common, other, and Git diff checks passed.
Next: Repair the non-rotate missing-trust branch, add its regression to the owning OpenVPN proof, then rerun proof/gate/evaluation.

Correction or repair context:
The user reduced the console to a visible single-action menu with options 1–5 and required visible preparation/OpenVPN checks. The first evaluator required exact mappings and visible successful helper output; the second required the terminal-preservation oracle to recognize real macOS clear behavior rather than only `ESC c`. The final proof drives all five options, compares the entire numbered menu exactly, verifies mappings/output, and rejects/self-tests RIS, form-feed, and CSI erase-display clearing sequences. Earlier evaluator failures are retained at `../20260803T095958802450Z/completion.md` and `../20260803T100633832018Z/completion.md`.

Queue invalidation: not applicable because this repository has no `docs/features/status.json`.
