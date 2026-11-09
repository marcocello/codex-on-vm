# Memory protection proof

The remote-control managed workspace preparation scenario exercises the production payload using fake Azure and machine boundaries. It verifies monitor installation, healthy and warning samples, swap creation and idempotence, and preservation of an existing swap configuration. Live read-back must separately verify the active swap file, its boot configuration, the enabled timer, and journal output on the intended VM. A reboot or external notification is not covered by these checks.

Run `docs/features/vm-memory-protection/proof/run.sh` from the repository root. The script also runs the existing preparation scenario.
