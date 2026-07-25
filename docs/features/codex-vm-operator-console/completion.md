# Completion

- Outcome: `scripts/codex-vm.sh` is the repository's only production shell script and contains all eight focused Mac helpers plus all six VM and Terraform payloads.
- Interaction: launching the console displays the menu before any preparation check. An unprepared protected action asks before setup in a terminal, while non-interactive commands stop with an explicit setup instruction.
- Focused proof: PASS at `proof/runs/20260725T064439004960Z`.
- Integration proof: PASS at `../remote-control-managed-workspace/proof/runs/20260725T064454026596Z`.
- Repository gate: the applicable `other` profile and Git diff checks PASS. The aggregate reports only the repository's pre-existing missing root `AGENTS.md`.
- Fresh evaluator: PASS. It confirmed menu-first rendering, consent and cancellation, setup-failure blocking, semantic marker validation, subscription safety, non-mutating dry-run, and the broader Terraform and VM regression evidence.
- Packaging: runtime extraction preserves the former helper boundaries in private mode-0700 temporary directories and removes them after each action. Terraform uses the private console entrypoint for local SSH-key preparation without receiving private key material.
