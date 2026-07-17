#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'SSH key bootstrap failed: %s\n' "$1" >&2
  exit 1
}

for command in python3 ssh-keygen; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done

INPUT="$(cat)"
MAC_PRIVATE_KEY="$(INPUT="$INPUT" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["INPUT"])
if set(value) != {"mac_private_key_path"}:
    raise SystemExit("expected only mac_private_key_path")
path = value["mac_private_key_path"]
if not path.startswith("/") or "\n" in path or "\t" in path:
    raise SystemExit("key path must be absolute and contain no control characters")
print(path)
PY
)"
PUBLIC_KEY="$MAC_PRIVATE_KEY.pub"

install -d -m 0700 "$(dirname "$MAC_PRIVATE_KEY")"
if [[ -f "$PUBLIC_KEY" && ! -f "$MAC_PRIVATE_KEY" ]]; then
  fail "public key exists without its private key: $PUBLIC_KEY"
fi
if [[ ! -f "$MAC_PRIVATE_KEY" ]]; then
  ssh-keygen -q -t ed25519 -a 100 -N "" -C "codex-on-vm-mac" -f "$MAC_PRIVATE_KEY"
fi
if [[ ! -f "$PUBLIC_KEY" ]]; then
  ssh-keygen -y -f "$MAC_PRIVATE_KEY" >"$PUBLIC_KEY"
fi

chmod 0600 "$MAC_PRIVATE_KEY"
chmod 0644 "$PUBLIC_KEY"
DERIVED_PUBLIC="$(ssh-keygen -y -f "$MAC_PRIVATE_KEY" | awk '{print $1 " " $2}')"
STORED_PUBLIC="$(awk '{print $1 " " $2}' "$PUBLIC_KEY")"
[[ "$DERIVED_PUBLIC" == "$STORED_PUBLIC" ]] || fail "public key does not match private key: $PUBLIC_KEY"

MAC_PUBLIC_KEY="$PUBLIC_KEY" python3 - <<'PY'
import json
import os

with open(os.environ["MAC_PUBLIC_KEY"], encoding="utf-8") as handle:
    mac = handle.read().strip()
print(json.dumps({"mac_public_key": mac}, sort_keys=True))
PY
