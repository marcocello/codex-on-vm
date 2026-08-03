# Proof

## Done

- Terraform mock planning proves infrastructure-only ownership, managed-disk protection, no cloud-init or guest Run Command resource, one OpenVPN ingress rule, and no TCP/22 ingress.
- Production embedded extraction and the machine-preparation scenario execute real payload assembly, checksum rejection, Azure Run Command read-back, persistent-home selection, idempotent preparation, one-host SSH configuration, sign-in, pairing, and disconnected VPN failure.
- The dot-codex feature proof exercises Git convergence, migration, Remote Control connection read-back, and rollback through the private alias.
- Persistent-home fixtures prove fresh selection, existing-state preservation, dot-codex preference, and exact symlink resolution.
- Every extracted production helper and VM payload passes Bash syntax validation.

## Command

```bash
"${CODEX_HOME:-$HOME/.codex}/scripts/proof_run_capture" --feature-dir docs/features/remote-control-managed-workspace --timeout-seconds 120 --note "exercise infrastructure-only setup, persistent Codex home, Remote Control, and VPN-only account access"
```

## Boundaries

Azure providers, VM agent transport, SSH network transport, and Codex account responses are deterministic fakes. Payload assembly, checksums, Terraform planning, local trust writes, persistent-home filesystem behavior, Git behavior, and shell programs are real. Live Azure replacement, OpenVPN packet flow, authentication, reboot, and restore drills remain outside this proof.
