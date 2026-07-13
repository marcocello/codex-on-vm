#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  printf 'usage: %s <https-url> <sha256> <output-path>\n' "$0" >&2
  exit 64
fi

URL="$1"
EXPECTED_SHA256="$2"
OUTPUT_PATH="$3"

[[ "$URL" == https://* ]] || {
  printf 'verified artifact URL must use HTTPS\n' >&2
  exit 65
}
[[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'expected SHA-256 must be 64 lowercase hexadecimal characters\n' >&2
  exit 65
}

for command in curl awk; do
  command -v "$command" >/dev/null || {
    printf 'missing required command: %s\n' "$command" >&2
    exit 69
  }
done

OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
if [[ ! -d "$OUTPUT_DIR" ]]; then
  install -d -m 0700 "$OUTPUT_DIR"
fi
TEMP_PATH="$(mktemp "${OUTPUT_PATH}.tmp.XXXXXX")"
trap 'rm -f "$TEMP_PATH"' EXIT

curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --output "$TEMP_PATH" "$URL"
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(sha256sum "$TEMP_PATH" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(shasum -a 256 "$TEMP_PATH" | awk '{print $1}')"
else
  printf 'missing SHA-256 command: sha256sum or shasum\n' >&2
  exit 69
fi

[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || {
  printf 'artifact SHA-256 mismatch for %s\n' "$URL" >&2
  exit 66
}

chmod 0600 "$TEMP_PATH"
mv -f "$TEMP_PATH" "$OUTPUT_PATH"
trap - EXIT
