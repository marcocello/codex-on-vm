# Completion

Proof: PASS — the production pseudo-terminal menu exposes exactly options 1–5, returns after one visible action, blocks options 2–5 before helper activation when OpenVPN is disconnected, and exercises the extracted production OpenVPN helper with real certificates. Ordinary repair rejects missing local trust before credential creation or remote mutation; only explicit `--rotate` creates replacement trust.

Gate: PASS — `${CODEX_HOME:-$HOME/.codex}/scripts/gate --root "$PWD"` passed common, other, and Git diff checks.

Evaluator:
Evaluator: PASS
Intent: Aligned with the corrected five-option, one-shot console and explicit-only OpenVPN trust rotation.
Behavior: Exact options 1–5, visible checks/output, setup’s VPN exception, disconnected guidance, and fail-closed ordinary `vpn-setup` are implemented; only `--rotate` reaches credential generation.
Architecture: Preserves the console dispatcher, centralized preflights, VPN-only SSH boundary, and Azure Run Command recovery path.
Proof realism: Current PASS matches saved contracts/runner; PTY coverage exercises all mappings and clearing behavior, while unchanged red-to-green OpenVPN proof exercises the extracted production helper with real certificates and verifies no local or remote mutation on missing trust.
False-green risk: No plausible central broken-pass remains; the former implicit-rotation implementation fails the retained regression.
Known gaps: Acceptable — live Azure, packet transport, macOS client state, and VS Code remain outside local proof.
Gate: PASS — canonical common, other, and Git diff checks passed.
Next: none

Correction or repair context:
The previous evaluator found that ordinary `vpn-setup` could silently create replacement trust when the local OpenVPN directory was missing and that the menu proof used a fake option-5 helper. The repair adds a fail-closed missing-trust guard and makes the operator proof run the owning OpenVPN trust scenario. The retained red attempt is `../../../self-hosted-openvpn-access/proof/runs/20260803T101523954000Z`.

Queue invalidation: not applicable because this repository has no `docs/features/status.json`.
