# Proof

## Done

- A pseudo-terminal drives the production no-argument menu and observes exactly options 1–5, one menu rendering, one selected action, visible output, and return to the shell. Options 6, 7, and 0 are absent.
- Help and parser expose only `setup`, `sign-in`, `pair`, `dot-codex`, `vpn-setup`, `menu`, and `help`; shell, status, public-SSH, and workspace commands are rejected.
- Dry-run output for options 2–5 visibly orders preparation check, VPN check, action activation, and result. Setup visibly activates without requiring VPN.
- With a prepared fake VM and disconnected fake VPN, each of options 2–5 fails with import/connect guidance before its embedded helper is invoked.
- Test-mode extraction materializes exactly five Mac helpers and seven VM payloads with no public-SSH or workspace lifecycle helper.
- Argument validation rejects unexpected values and preserves only `vpn-setup --rotate`.

## Command

```bash
"${CODEX_HOME:-$HOME/.codex}/scripts/proof_run_capture" --feature-dir docs/features/codex-vm-operator-console --timeout-seconds 30 --note "exercise visible single-action menu, centralized VPN preflight, reduced command surface, and embedded bundle"
```

## Boundaries

The proof executes the production parser, menu through a pseudo-terminal, dry-run ordering, preparation/VPN checks through deterministic outer-edge fakes, helper activation boundary, embedded extractor, and Bash syntax checks. Live Azure, OpenVPN packet transport, SSH authentication, and Remote Control are owned by their feature proofs.
