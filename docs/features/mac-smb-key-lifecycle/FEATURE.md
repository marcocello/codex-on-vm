# Mac SMB Shared-Key Lifecycle

> Superseded by `docs/features/remote-control-managed-workspace`. This contract and its captured runs are historical and do not describe the current production Terraform root.

## Summary
Keep the macOS Azure Files SMB workflow while ensuring the temporary firewall rule and Storage `key2` credential have an explicit, failure-safe lifecycle.

## Desired Behavior
- Opening an SMB session temporarily allowlists only the current public IPv4 address, exposes `key2` only through the macOS password-prompt clipboard handoff, clears the clipboard after the mount attempt, and records only a non-secret key fingerprint in the session state.
- Closing a session unmounts the share, removes and verifies removal of the exact firewall rule, rotates `key2`, verifies the returned key differs from the exposed credential, and removes session state only after rotation succeeds.
- A failed open removes its firewall rule, clears the clipboard, and rotates any key that was exposed; if rotation cannot be completed, recovery state remains so `smb-close.sh` can retry it.
- Concurrent open or close operations for the same state file fail closed through a local session lock.

## Constraints
- Direct macOS SMB access remains supported; Azure Files SMB does not use a SAS token as a password replacement.
- `key1` is not read or rotated because the VM now uses managed-identity SMB authentication.
- No account key is written to disk, Terraform state, logs, command arguments, or the session-state file.
- Existing session-state files without a key fingerprint remain closeable and still cause `key2` rotation.
- No live Azure firewall mutation, mount, or key rotation is part of the local implementation proof.

## Implementation Routing
- Required skills: coding-feature-execute, coding-proof-author
