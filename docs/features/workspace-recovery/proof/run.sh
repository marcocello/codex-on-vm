#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
terraform -chdir="$ROOT/deployment/prod/tf" test -filter=tests/workspace_recovery.tftest.hcl -verbose
