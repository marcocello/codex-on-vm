# Proof

## Done

- The exact production `scripts/codex-vm.sh` displays a usable pseudo-terminal menu and delegates a selected action before returning to the menu.
- `scripts/codex-vm.sh` is the only production shell script under `scripts/` or `deployment/prod/tf/`; the eight former Mac helper paths and six former deployment payload paths are absent.
- Test-mode extraction materializes all eight Mac helpers and six VM/Terraform payloads into a private fixture root, with the production Terraform tree linked at the path expected by the helpers.
- Terraform references the private console SSH-key entrypoint. That entrypoint creates a real ephemeral Ed25519 pair through the embedded payload, returns only the public key JSON, preserves required file modes, and removes its temporary runtime root.
- A public `ssh-close` command without test-helper override exercises the production temporary-runtime branch; provider read-back observes mode-0700 runtime directories and all fourteen executable bundle files before post-command read-back proves the runtime root was removed.
- An unprepared interactive launch displays the menu before any Terraform, Azure, setup, or action call.
- Selecting a protected menu action while unprepared explains the requirement and asks for confirmation. An affirmative answer runs setup before the action, a negative answer runs neither, and accepted setup failure blocks the action while leaving the menu available.
- Every unprepared protected command (`pair`, `dot-codex`, `shell`, and `workspace-open`) invoked without a terminal fails with an actionable setup instruction and runs neither setup nor the requested action.
- An unprepared protected command invoked in a terminal asks for confirmation. An affirmative answer runs setup before the action, while a negative answer cancels without either helper.
- A current preparation marker allows dependent workflows to continue without repeating setup, while help, status, and cleanup commands never force preparation.
- The actual Run Command marker script is executed against current, stale, malformed, unreadable, missing, and unreachable fixture states. Only the current Terraform Codex version and projects mount skip the confirmation requirement.
- An active Azure subscription mismatch fails before the marker check, setup, or requested action.
- The old first-step warning is absent from help, setup output, and the menu because ordering is enforced by behavior.
- The distinct `setup`, `pair`, and `dot-codex` subcommands dispatch to their embedded helpers with exact arguments.
- Removed `deploy`, legacy workflow names, `ssh-open`, and `--yes` are absent from help and rejected before external calls.
- Dry-run, invalid command, and invalid workspace input produce no external calls.
- A failed interactive SSH client still closes temporary SSH.
- Status reads the expected Terraform, Azure, local trust, rule, and mount boundaries without invoking a mutating helper.

## Command

```bash
"${CODEX_HOME:-$HOME/.codex}/scripts/proof_run_capture" --feature-dir docs/features/codex-vm-operator-console --timeout-seconds 40 --note "Exercise the unified interactive and noninteractive Codex VM operator workflows"
```

## Scenario: Explicit operator workflows

- Producer/activation: the proof invokes an exact copy of `scripts/codex-vm.sh` with each public subcommand and global flag.
- Consumer: the production argument parser, command dispatcher, complete bundle materializer, private Terraform entrypoint, stage UI, and cleanup traps execute unchanged.
- Read-back: the real embedded SSH-close helper observes its private runtime root through the fake Terraform edge; a report records root, scripts, VM payload, file modes, and Terraform-tree link while the helper runs, then the proof requires the runtime root to be absent after return. A real ephemeral key fixture reads back public/private agreement and modes through the private Terraform path. The Azure boundary executes the generated marker-validation script against fixture files, while pseudo-terminal sessions and separate subprocess logs record menu-first rendering, confirmation, consent or cancellation, exact delegated helpers, fail-closed subscription targeting, Terraform-output, Azure, SSH, and mount calls.
- Fake: Terraform, Azure CLI, SSH, mount, and OS detection are replaced. Test-helper overrides remain limited to focused dispatch scenarios; the production-runtime scenario removes that override and executes the actual embedded SSH-close source.
- Catches: setup before the menu, automatic setup without consent, a prompt that ignores a negative answer, protected action before accepted setup, continued action after setup failure, non-interactive mutation, marker-existence-only validation, prompting despite a current marker, setup against the wrong subscription, cleanup blocked by missing preparation, Terraform key bootstrap disconnected from the console, private-key leakage, non-private extraction, missing payload executability, incorrect Terraform linkage, or cleanup omission.

## Scenario: Interactive menu

- Producer/activation: Python allocates a real pseudo-terminal, launches the production console with no arguments, selects “Set up or repair Codex on the VM,” acknowledges its result, then exits.
- Consumer: terminal detection, menu rendering, input parsing, dispatcher, and return-to-menu loop remain production code.
- Read-back: a successful setup and an injected setup failure must each render the menu again before exit. Terminal output contains the banner, distinct menu labels, stage, completion or failure result, while each complete call log records only the preparation-helper boundary exactly once.
- Fake: only the delegated preparation helper is replaced.
- Catches: a command that works only through subcommands, reads redirected stdin instead of the controlling terminal, exits after its first success, exits after an action failure, or never delegates the selection.

## Scenario: Failure cleanup and dry-run

- Producer/activation: the SSH executable returns an injected failure after restricted access opens; separate dry-run and invalid-input invocations execute through the same public parser.
- Consumer: the production shell workflow, exit trap, dry-run dispatcher, and validation logic run unchanged.
- Read-back: ordered calls require stale-state close, open, SSH failure, and final close; access state must be absent. Dry-run and invalid input leave the call log empty.
- Fake: SSH and the existing SSH open/close helpers expose deterministic call and state files.
- Catches: cleanup only on success, a dry-run that still mutates, or validation after delegation.

## Scope

Proves:

- One production command owns discovery and orchestration while preserving the existing helper boundaries.
- One checked-in production shell script contains all local helpers and VM payload implementations and recreates their executable boundaries only in a temporary runtime root.
- The public command path, not only the guarded extraction interface, creates private executable helpers and cleans them up after execution.
- Interactive and explicit automation surfaces cover the accepted normal workflows.
- Manual-Terraform separation, removed-command rejection, dry-run behavior, argument forwarding, and SSH cleanup are observable.

Does not prove:

- Live Terraform, Azure, SSH, Remote Control, device authentication, SSHFS, backup, or restore behavior; those remain owned by their existing feature proofs and live workflows.
- Terminal rendering in every emulator or accessibility configuration.

False-green risks:

- Executable fakes cannot reproduce provider latency or an operator closing the terminal during an uncatchable process termination.
- ANSI layout can render differently across terminals, but required text and action behavior are read back independently of color.

Evidence method:

- Deterministic CLI/subprocess proof with a real pseudo-terminal.

Known gaps:

- Live provider and interactive ChatGPT pairing behavior remain outside this orchestration proof.

Proof runner corrections:

- 2026-07-24: after implementation began, the helper fake was corrected to omit a synthetic `''` argument when a zero-argument helper ran, and the pseudo-terminal status variables were initialized before polling. The menu had delegated correctly; this was a mechanical evidence-recording defect, and the production scenarios and assertions were not reduced.
- 2026-07-24: the first fresh evaluator rejected the then-current deployment proof because it did not exercise interactive rejection. That proof was strengthened and passed before the user subsequently removed deployment from the console.
- 2026-07-24 user correction: Terraform is manual, public open-SSH is removed, and the four post-Terraform workflows use distinct outcome names. Deployment assertions were replaced with negative proof that `deploy`, `--yes`, `ssh-open`, and confusing legacy workflow names are absent and cannot make external calls. This changes the accepted behavior rather than weakening proof for the old contract.
- 2026-07-24: the first evaluator of the simplified console found that the PTY menu scenario required the new labels without excluding all four old labels, and counted setup without excluding extra calls. The strengthened read-back now rejects every legacy label and requires the complete menu-action log to equal one preparation-helper call, so Terraform or any other extra action cannot hide beside setup.
- 2026-07-24: the next evaluator found that the PTY input sequence did not prove the menu rendered again and did not inject an action failure. The proof now runs separate successful and failing setup sessions, requires two console-banner renderings in each, and checks the visible failure before exit.
- 2026-07-24 user correction: setup and Remote Control repair are one idempotent operator outcome, pairing remains separate, and dot-codex should explicitly describe cloning or updating from GitHub. The public `repair` and `sync-config` commands are removed; `dot-codex` is restored as the clearer name, while the recovery helper remains an internal implementation dependency.
- 2026-07-24: the corrected help proof initially treated the word “repair” in the combined setup description as a legacy command. The mechanical assertion now matches command and option rows, preserving removed-command coverage without forbidding the accepted label.
- 2026-07-24 user correction: all Mac helpers must be in one physical script and unused source files removed. The selected design embeds the existing helper bodies and materializes them privately at runtime so their isolation, traps, and cross-calls survive; VM payload scripts remain separate direct dependencies.
- 2026-07-24: the first evaluator of the one-file correction found that dispatch tests used test-helper overrides while the integration suite invoked extracted helpers directly. The proof now drives a public command through the normal materialize-and-execute branch, reads mode and linkage state while the helper is active, and requires post-command cleanup.
- 2026-07-24 user correction: the one-file boundary now includes the six former `deployment/prod/tf/scripts/*.sh` payloads. Terraform retains pre-creation key generation through a private console entrypoint, while `setup` extracts every VM payload and is visibly identified as the first post-apply action.
- 2026-07-25 user correction: replace the first-step warning with enforcement. The console now treats the version-and-mount preparation marker as authoritative and automatically runs setup before dependent explicit or interactive workflows.
- 2026-07-25: after the first green implementation run, the preparation fake was strengthened to return ready only when the production Run Command payload checks both the current Terraform Codex version and projects mount. Explicit read-back assertions retain those values in the call log, preventing a marker-existence-only implementation from passing.
- 2026-07-25: the first evaluator of the enforced gate found that the focused runner covered only unprepared `pair` and menu paths and matched marker-script substrings without executing the script. The proof now executes the generated check against current, stale, malformed, unreadable, missing, and unreachable marker states; covers automatic setup and setup-failure blocking for every protected command and menu launch; and proves subscription mismatch stops before Run Command or setup.
- 2026-07-25 user correction: launching the console must show the options before any setup decision. When a protected action needs preparation, the console asks before running setup; declining cancels the action, and a non-interactive command fails instead of assuming consent. The previous automatic-setup expectations were replaced with consent, cancellation, and menu-first assertions.

## Environment

- macOS Bash 3.2+, Python 3 pseudo-terminal support, and temporary executable fakes.
- No Azure, Terraform backend, SSH, or ChatGPT credentials are required.
- Runner stdout prints the Bash and Python executable paths/versions and the fake-edge mode.
