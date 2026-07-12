#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'SSH key bootstrap failed: %s\n' "$1" >&2
  exit 1
}

for command in openssl python3 ssh-keygen; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done

INPUT="$(cat)"
IFS=$'\t' read -r MAC_PRIVATE_KEY MOBILE_PRIVATE_KEY <<<"$(INPUT="$INPUT" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["INPUT"])
required = {"mac_private_key_path", "mobile_private_key_path"}
if set(value) != required:
    raise SystemExit(f"expected query keys {sorted(required)}")
paths = [value["mac_private_key_path"], value["mobile_private_key_path"]]
if any(not path.startswith("/") or "\n" in path or "\t" in path for path in paths):
    raise SystemExit("key paths must be absolute and contain no control characters")
print("\t".join(paths))
PY
)"

ensure_pair() {
  local private_key="$1"
  local label="$2"
  local public_key="$private_key.pub"

  install -d -m 0700 "$(dirname "$private_key")"
  if [[ -f "$public_key" && ! -f "$private_key" ]]; then
    fail "public key exists without its private key: $public_key"
  fi
  if [[ ! -f "$private_key" ]]; then
    ssh-keygen -q -t ed25519 -a 100 -N "" -C "$label" -f "$private_key"
  fi
  if [[ ! -f "$public_key" ]]; then
    ssh-keygen -y -f "$private_key" >"$public_key"
  fi

  chmod 0600 "$private_key"
  chmod 0644 "$public_key"
  local derived_public stored_public
  derived_public="$(ssh-keygen -y -f "$private_key" | awk '{print $1 " " $2}')"
  stored_public="$(awk '{print $1 " " $2}' "$public_key")"
  [[ "$derived_public" == "$stored_public" ]] || fail "public key does not match private key: $public_key"
}

derive_mobile_public() {
  local private_key="$1"
  openssl pkey -in "$private_key" -pubout -outform DER 2>/dev/null \
    | python3 -c 'import base64,struct,sys
der = sys.stdin.buffer.read()
prefix = bytes.fromhex("302a300506032b6570032100")
if len(der) != len(prefix) + 32 or not der.startswith(prefix):
    raise SystemExit("unexpected Ed25519 SubjectPublicKeyInfo")
raw = der[len(prefix):]
pack = lambda value: struct.pack(">I", len(value)) + value
blob = pack(b"ssh-ed25519") + pack(raw)
print("ssh-ed25519 " + base64.b64encode(blob).decode() + " codex-on-vm-mobile")'
}

ensure_mobile_pair() {
  local private_key="$1"
  local public_key="$private_key.pub"

  install -d -m 0700 "$(dirname "$private_key")"
  if [[ -f "$public_key" && ! -f "$private_key" ]]; then
    fail "public key exists without its private key: $public_key"
  fi
  if [[ ! -f "$private_key" ]]; then
    umask 077
    openssl genpkey -algorithm ED25519 -out "$private_key" 2>/dev/null
  fi
  local pkcs8_header="-----BEGIN PRIVATE"" KEY-----"
  [[ "$(sed -n '1p' "$private_key")" == "$pkcs8_header" ]] \
    || fail "mobile private key must be Ed25519 PKCS#8 PEM: $private_key"
  openssl pkey -in "$private_key" -noout >/dev/null 2>&1 \
    || fail "mobile PKCS#8 private key is invalid: $private_key"

  local derived_public stored_public
  derived_public="$(derive_mobile_public "$private_key")"
  if [[ ! -f "$public_key" ]]; then
    printf '%s\n' "$derived_public" >"$public_key"
  fi
  chmod 0600 "$private_key"
  chmod 0644 "$public_key"
  stored_public="$(awk '{print $1 " " $2}' "$public_key")"
  [[ "${derived_public% codex-on-vm-mobile}" == "$stored_public" ]] \
    || fail "public key does not match mobile private key: $public_key"
}

[[ "$MAC_PRIVATE_KEY" != "$MOBILE_PRIVATE_KEY" ]] || fail "Mac and mobile key paths must differ"
ensure_pair "$MAC_PRIVATE_KEY" "codex-on-vm-mac"
ensure_mobile_pair "$MOBILE_PRIVATE_KEY"

MAC_PUBLIC_KEY="$MAC_PRIVATE_KEY.pub" MOBILE_PUBLIC_KEY="$MOBILE_PRIVATE_KEY.pub" python3 - <<'PY'
import json
import os

with open(os.environ["MAC_PUBLIC_KEY"], encoding="utf-8") as handle:
    mac = handle.read().strip()
with open(os.environ["MOBILE_PUBLIC_KEY"], encoding="utf-8") as handle:
    mobile = handle.read().strip()
print(json.dumps({"mac_public_key": mac, "mobile_public_key": mobile}, sort_keys=True))
PY
