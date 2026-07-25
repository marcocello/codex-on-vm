# Codex VM operator console

## Goal

A Mac operator can use one polished repository command to discover and launch every normal Codex-on-VM workflow.

## Behavior

- `scripts/codex-vm.sh` is the documented operator-facing entrypoint.
- `scripts/codex-vm.sh` is the repository's only production shell script. Setup, pairing, dot-codex, recovery, SSH, workspace, Terraform SSH-key bootstrap, verified installation, persistent-home selection, daemon recovery, and VM preparation implementations are embedded in that file.
- Runtime materialization uses mode-0700 directories and executable files, links the temporary root to the checkout's real Terraform tree, preserves helper-to-helper and guest-payload calls, and removes the temporary root when the console exits.
- Terraform invokes a private, undocumented `codex-vm.sh` entrypoint for local Ed25519 key preparation before VM creation. The private key remains in the operator-selected local path and never enters Terraform output or state.
- The interactive menu is displayed immediately without checking preparation or running setup.
- Before executing `pair`, `dot-codex`, `shell`, or `workspace-open`, the console verifies through Azure Run Command that `/var/lib/codex-on-vm/prepared` matches the current Terraform Codex version and projects mount. When preparation is missing, stale, unreadable, or unreachable on an interactive terminal, the console explains that setup is required and asks whether to run the existing idempotent `setup` workflow first.
- Setup runs only after an explicit affirmative answer. Declining cancels the requested action and returns to the menu when applicable. A protected command without an interactive terminal fails with an instruction to run `scripts/codex-vm.sh setup`; it never assumes consent.
- When accepted setup fails, the requested dependent action does not run. A subscription mismatch fails closed without offering or attempting setup against another Azure subscription.
- `help`, `status`, `setup`, `ssh-close`, and `workspace-close` remain directly available without the preparation gate so discovery, inspection, explicit repair, and cleanup are always possible.
- With no arguments, an interactive terminal shows a styled, repeatable menu and returns to that menu after each completed or failed action until the operator exits.
- Explicit subcommands support `setup`, `pair`, `dot-codex`, `shell`, `ssh-close`, `workspace-open`, `workspace-close`, `status`, `menu`, and `help`.
- The three primary workflows describe distinct operator outcomes: `setup` installs or repairs Codex and Remote Control after Terraform has been applied manually, `pair` signs in and pairs a device, and `dot-codex` clones or safely updates the persistent dot-codex configuration from its GitHub origin.
- `setup`, `pair`, `dot-codex`, SSH cleanup, and workspace actions run the embedded focused helper implementations. Consolidation does not change their Azure targeting, checksum, persistence, authentication, Git, temporary-ingress, mount, or cleanup behavior.
- `shell` normalizes stale temporary SSH state, opens restricted SSH, starts an interactive SSH client, and closes temporary SSH on success, failure, interruption, or normal exit.
- The console does not expose a standalone action whose only outcome is leaving SSH open. `ssh-close` remains as an emergency cleanup action; workspace mounting manages temporary SSH for the mount lifecycle.
- `workspace-open` accepts zero arguments for the default projects directory or one absolute remote path. `workspace-close` unmounts before closing temporary SSH through the existing helper.
- `status` reads Terraform connection output, active Azure subscription, VM power and agent state, temporary SSH rule state, local SSH trust files, and local workspace mount state without changing them.
- `--dry-run` prints the requested action and explains that setup would require confirmation, without making the remote marker check, prompting, or executing setup. `--no-color` disables ANSI styling.
- Invalid commands, removed legacy commands, unexpected arguments, relative workspace paths, a default menu without a terminal, missing prerequisites, and subscription mismatch fail before the corresponding external mutation.
- Failures show the failed stage, retain downstream helper output, and provide the next useful command.

## External Contract

```text
scripts/codex-vm.sh [--dry-run] [--no-color] <command> [command arguments]
```

- Global flags may precede the command.
- `workspace-open` is the only command that accepts a positional argument.
- The command is macOS-only except for `help`.
- The embedded-helper extraction interface is guarded by test mode and is not listed as an operator command.
- The private Terraform SSH-key interface is referenced only by Terraform and is not listed as an operator command.

## Constraints

- Terraform is run manually and remains outside the console. The console may read Terraform outputs for targeting and status but must never run Terraform init, plan, apply, or destroy.
- Every one-time preparation, authentication, recovery, and access action begins on the Mac.
- The console must never add a destroy, protection-removal, force-reset, broad-ingress, credential-printing, or secret-storage workflow.
- The console must not expose a standalone open-SSH workflow.
- The console must preserve cleanup authority in its embedded SSH-close and workspace-close helpers.
- `deployment/prod/tf/scripts/` contains no production shell payloads; all guest payload source is extracted from `scripts/codex-vm.sh` immediately before local transmission or Terraform key preparation.
- Bash 3.2 compatibility is required on macOS.
- No optional UI dependency may be downloaded or installed by the console.

## Non-Goals

- Changing the focused helper or guest-payload behavior while consolidating its physical packaging.
- Automating destructive decommissioning, backup restore, Azure subscription creation, credential entry, or ChatGPT pairing input.
- Providing a Linux or Windows operator interface.
