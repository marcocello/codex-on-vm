#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OPERATOR_ROOT="$TMP/operator-root"
CODEX_VM_TEST_MODE=1 "$ROOT/scripts/codex-vm.sh" __extract-helpers "$OPERATOR_ROOT"
LOCAL_PREPARER="$OPERATOR_ROOT/scripts/prepare-machine.sh"
INSTALLER="$OPERATOR_ROOT/vm-scripts/install-verified-codex.sh"
FETCHER="$OPERATOR_ROOT/vm-scripts/fetch-verified-artifact.sh"
VM_PREPARER="$OPERATOR_ROOT/vm-scripts/prepare-codex-vm.sh"

terraform -chdir="$TF_DIR" test -filter=tests/pinned_root_provisioning.tftest.hcl

[[ -x "$INSTALLER" ]]
[[ -x "$FETCHER" ]]
[[ -x "$LOCAL_PREPARER" ]]
[[ -x "$VM_PREPARER" ]]
if rg -n '^[[:space:]]*custom_data[[:space:]]*=' "$TF_DIR" --glob '*.tf' >/dev/null; then
  printf 'Terraform must not activate the root installer through custom data\n' >&2
  exit 1
fi
rg -F '/usr/local/sbin/install-verified-codex' "$VM_PREPARER" >/dev/null
rg -F 'install_checked' "$LOCAL_PREPARER" >/dev/null
if rg -F 'https://chatgpt.com/codex/install.sh' "$LOCAL_PREPARER" "$VM_PREPARER" >/dev/null; then
  printf 'local preparation must not use the mutable Codex installer\n' >&2
  exit 1
fi

PACKAGE="$TMP/package"
mkdir -p "$PACKAGE/bin" "$PACKAGE/codex-path" "$PACKAGE/codex-resources"
cat >"$PACKAGE/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex-cli 0.144.3\n'
EOF
cat >"$PACKAGE/bin/codex-code-mode-host" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$PACKAGE/codex-path/rg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$PACKAGE/codex-resources/bwrap" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
printf '{"version":"0.144.3"}\n' >"$PACKAGE/codex-package.json"
chmod +x "$PACKAGE/bin/codex" "$PACKAGE/bin/codex-code-mode-host" "$PACKAGE/codex-path/rg" "$PACKAGE/codex-resources/bwrap"
tar -czf "$TMP/codex-package.tgz" -C "$PACKAGE" .
GOOD_SHA="$(shasum -a 256 "$TMP/codex-package.tgz" | awk '{print $1}')"

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$output" ]]
cp "$TEST_ARTIFACT" "$output"
EOF
chmod +x "$FAKE_BIN/curl"

export PATH="$FAKE_BIN:$PATH"
export TEST_ARTIFACT="$TMP/codex-package.tgz"

SHARED_PARENT="$TMP/shared-parent"
install -d -m 1777 "$SHARED_PARENT"
"$FETCHER" "https://example.invalid/codex-package.tgz" "$GOOD_SHA" "$SHARED_PARENT/fetched-package.tgz"
python3 - "$SHARED_PARENT" <<'PY'
import pathlib
import stat
import sys

mode = stat.S_IMODE(pathlib.Path(sys.argv[1]).stat().st_mode)
if mode != 0o1777:
    raise SystemExit(f"verified fetch changed existing parent mode to {mode:o}")
PY

"$INSTALLER" "https://example.invalid/codex-package.tgz" "$GOOD_SHA" "0.144.3" "$TMP/good-home" "$TMP/good-bin" "$FETCHER"
[[ "$("$TMP/good-bin/codex" --version)" == "codex-cli 0.144.3" ]]
[[ -L "$TMP/good-home/packages/standalone/current" ]]
[[ -x "$TMP/good-home/packages/standalone/current/codex" ]]
[[ -x "$TMP/good-home/packages/standalone/releases/0.144.3-x86_64-unknown-linux-musl/bin/codex" ]]

printf 'tampered' >>"$TMP/codex-package.tgz"
if "$INSTALLER" "https://example.invalid/codex-package.tgz" "$GOOD_SHA" "0.144.3" "$TMP/bad-home" "$TMP/bad-bin" "$FETCHER"; then
  printf 'expected digest mismatch to reject the package\n' >&2
  exit 1
fi
[[ ! -e "$TMP/bad-bin/codex" ]]
[[ ! -e "$TMP/bad-home/packages/standalone/releases/0.144.3-x86_64-unknown-linux-musl" ]]

bash -n "$FETCHER" "$INSTALLER" "$LOCAL_PREPARER" "$VM_PREPARER"
terraform -chdir="$TF_DIR" fmt -check -recursive
terraform -chdir="$TF_DIR" validate
printf 'Pinned root provisioning proof passed.\n'
