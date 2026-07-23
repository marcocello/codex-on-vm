# Proof Plan

> Superseded by `docs/features/remote-control-managed-workspace`. This proof is retained as historical evidence only.

## Definition Of Done
- The real open command mounts through a temporary firewall rule, leaves a recovery state containing only a key fingerprint, and clears the clipboard.
- The real close command unmounts, removes the rule, rotates `key2`, and removes state only after successful rotation.
- A failed mount removes the rule, clears the clipboard, and rotates the exposed key.
- A failed close rotation retains state and a retry completes cleanup.

## Primary Proof
Type: cli-subprocess

Boundary:
- Producer: A Mac operator invokes `scripts/smb-open.sh` and `scripts/smb-close.sh`.
- Activation path: The production shell entrypoints execute unchanged with fake external commands earlier on `PATH`.
- Consumer: The scripts manage mount, clipboard, local state, Azure Storage firewall rules, and `key2` rotation.
- Durable state: Fake mount, firewall, clipboard, key-version, event log, and real JSON session-state files under a temporary directory.
- Read-back: The proof inspects every durable fake boundary plus operation order after success and injected failures.
- Unsafe edge: macOS mount/clipboard commands and live Azure CLI calls are replaced by subprocess-compatible fakes.

Command:
```bash
scripts/proof_run_capture --serious --feature-dir docs/features/mac-smb-key-lifecycle --source-path scripts/smb-open.sh --source-path scripts/smb-close.sh --source-path docs/features/mac-smb-key-lifecycle/proof/run.sh --behavior-boundary "Mac operator -> real SMB lifecycle commands -> subprocess boundaries -> mount firewall clipboard key and state read-back" --oracle-scope "$(cat docs/features/mac-smb-key-lifecycle/PROOF.md)" --notes "Mac SMB sessions clear credentials, remove firewall access, and rotate key2 on close and failed open" -- docs/features/mac-smb-key-lifecycle/proof/run.sh
```

Expected evidence:
- Successful open/close leaves no mount, firewall rule, clipboard value, session state, or lock and changes `key2`.
- Failed open leaves no exposure and changes `key2`.
- Injected rotation failure leaves recovery state, and retry removes it after rotation.

## Claimed Behavior Coverage
| FEATURE claim | Real production entrypoint proof drives | Fake boundary used | Read-back |
| --- | --- | --- | --- |
| Successful session has bounded credential and firewall lifecycle | `scripts/smb-open.sh` then `scripts/smb-close.sh` | Azure CLI, macOS mount and clipboard | Files representing rule, mount, clipboard, key and JSON state |
| Failed mount revokes exposed access | `scripts/smb-open.sh` with mount failure | Same outer subprocess boundaries | Rule absent, clipboard empty, key changed, state absent after rotation |
| Rotation failure is retryable | `scripts/smb-close.sh` with injected renew failure, then retry | Azure CLI renew call | State retained after failure and removed after retry |
| Concurrent lifecycle operations fail closed | Real scripts acquire the production state lock | None for filesystem locking | Lock ownership and absence after exit |

## Fake Boundary Ledger
- Fake: Terraform output, Azure CLI, public-IP lookup, TCP probe, macOS mount, unmount, mount listing, clipboard, and polling sleep commands.
- Allowed because: The proof must not mutate a live storage firewall, rotate a live credential, or mount a paid Azure share.
- Not faked: Both production lifecycle scripts, their state transitions, locking, credential handling, cleanup ordering, error paths, and durable read-back.

## Proof Scope
Proves:
- The local operator commands enforce the intended lifecycle when external commands return the modeled success and failure results.

Does not prove:
- Live Azure propagation timing, macOS password-prompt behavior, actual SMB connectivity, Azure CLI authentication, or successful live key rotation.

False-green risks:
- A fake Azure response may differ from a future Azure CLI output shape.
- `SIGKILL`, host power loss, or a machine crash cannot run shell cleanup; retained session state supports later recovery but cannot itself revoke access while the Mac is offline.

Evidence strength:
- deterministic local CLI lifecycle proof with live-provider gap

## Secondary Guards
- `bash -n scripts/smb-open.sh scripts/smb-close.sh`
- `git diff --check`

## Environment And Data
- Bash, Python 3, and standard macOS-compatible command interfaces.
- Temporary fake provider state only; no Azure credentials or secrets.

## Anti-Gaming Review
- Fake pass risk: remove the firewall rule but leave the exposed key valid. Proof catch: key material must change after close and failed open.
- Fake pass risk: rotate the key but delete state before a failed rotation. Proof catch: injected renew failure must retain state and a retry must succeed.
- Fake pass risk: clear state but leave clipboard or mount active. Proof catch: each durable fake boundary is independently read back.
- Broken implementation that would still pass: cleanup cannot run after `SIGKILL` or power loss; live operational monitoring or an expiring access mechanism would be needed to close that platform-level gap.

## Proof Change Guard
- The original proof was incomplete because it asserted only that locks were cleaned up after normal and failed commands; it never invoked either production command while another operation owned the lock.
- The strengthened scenario catches implementations that create and remove lock paths but do not actually fail closed on contention.
- The initial evaluator recorded `FAIL` against evidence run `20260713T071357Z`; the strengthened proof must show both commands fail without changing provider, mount, clipboard, key, or session state before a replacement evaluation can pass.
- Behavior scope is unchanged: this adds evidence for the existing concurrency claim and removes nothing.

## Manual Gaps
- A reviewed live open/close, observed firewall read-back, key-version change, and remount with the new key remain required before production operation is claimed.
