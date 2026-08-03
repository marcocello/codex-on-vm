# Completion

- Captured proof: `proof/runs/20260803T093526172950Z` — PASS.
- Earlier evaluator: FAIL because the public `shell` command targeted the VPN alias without a bounded disconnected preflight or connect-OpenVPN instruction.
- Repair evidence: `proof/runs/20260803T093424868107Z` captured the strengthened shell regression failing for the reported reason; the console now checks reachability before interactive SSH, and the final proof captures it passing.
- Proof revision reason: the evaluator exposed a real false-green gap, so `proof/run.sh` was strengthened to execute the public shell boundary with a disconnected VPN fake and verify guidance plus absence of interactive SSH activation. The declared behavior was not narrowed.
- Focused regressions: operator console, dot-codex bootstrap, and managed workspace proofs — PASS.
- Live read-back: Azure NSG contains only `AllowOpenVpn` on inbound UDP/1194.
- Mac cleanup: active project SSH fragment contains only `codex-on-vm-vpn`; obsolete mobile key pair and SMB access state were removed. The main Mac SSH key, dedicated known-hosts file, and OpenVPN profile were retained for VS Code Remote-SSH.
- Repository gate: PASS after the evaluator repair (`gate --root "$PWD"`).
- Managed evaluator: PASS after the disconnected-shell repair; no plausible central false green remains.
- Queue invalidation: skipped because this repository has no `docs/features/status.json`.
- Known gap: the OpenVPN client was not connected during final local verification, so live SSH/VS Code reachability remains an operator check after connecting the profile.
