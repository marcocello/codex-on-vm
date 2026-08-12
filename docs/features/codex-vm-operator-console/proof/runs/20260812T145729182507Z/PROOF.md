# Proof

## Done

- A pseudo-terminal drives every production menu choice, compares the complete numbered menu exactly to options 1–6, rejects terminal reset, erase-display, and form-feed clearing sequences, verifies each exact helper/mode mapping, observes successful helper output plus visible checks, and requires one render followed by return to the shell. One preparation fixture deliberately delays Azure Run Command and requires target, activation, and elapsed-time output before completion.
- Help and parser expose only `setup`, `sign-in`, `pair`, `dot-codex`, `telegram-to-agents`, `vpn-setup`, `menu`, and `help`; shell, status, public-SSH, and workspace commands are rejected.
- Dry-run output for options 2–6 visibly orders preparation check, VPN check, action activation, and result. Setup visibly activates without requiring VPN.
- With a prepared fake VM and disconnected fake VPN, each of options 2–6 fails with import/connect guidance before its embedded helper is invoked.
- Test-mode extraction materializes exactly six Mac helpers and seven VM payloads with no public-SSH or workspace lifecycle helper.
- The extracted telegram-to-agents helper is executed against deterministic SSH and real Git boundaries. It proves the default repository and persistent clone path, rejects dirty/wrong-origin/detached or divergent checkouts, fast-forwards a clean tracked checkout, requires installation from that exact checkout, verifies the CLI link targets its isolated environment, invokes first-run onboarding only when configuration is absent, and requires restart to transition an existing inactive service back to active. Seeded Codex and Claude configuration files remain byte-for-byte unchanged, and a restart that leaves the service inactive fails the action.
- The extracted production OpenVPN helper rejects ordinary repair when local trust is missing and permits replacement trust only through explicit `--rotate`.
- Argument validation rejects unexpected values and preserves only `vpn-setup --rotate`.

## Command

```bash
"${CODEX_HOME:-$HOME/.codex}/scripts/proof_run_capture" --feature-dir docs/features/codex-vm-operator-console --timeout-seconds 90 --note "exercise visible single-action menu, centralized VPN preflight, explicit-only trust rotation, reduced command surface, and embedded bundle"
```

## Boundaries

The proof executes the production parser, every menu choice through a pseudo-terminal, successful and disconnected preparation/VPN checks through deterministic outer-edge fakes, exact helper activation and output propagation, dry-run ordering, embedded extractor, the production OpenVPN helper with real certificates and fake unsafe edges, and Bash syntax checks. Live Azure, OpenVPN packet transport, SSH authentication, and Remote Control remain outside this proof.
