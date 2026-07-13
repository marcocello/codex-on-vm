#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  printf 'usage: %s <package-url> <sha256> <version> <codex-home> <bin-dir> <verified-fetch-command>\n' "$0" >&2
  exit 64
fi

PACKAGE_URL="$1"
PACKAGE_SHA256="$2"
VERSION="$3"
CODEX_HOME="$4"
BIN_DIR="$5"
FETCH_COMMAND="$6"
TARGET="x86_64-unknown-linux-musl"
STANDALONE_ROOT="$CODEX_HOME/packages/standalone"
RELEASES_DIR="$STANDALONE_ROOT/releases"
RELEASE_DIR="$RELEASES_DIR/$VERSION-$TARGET"
CURRENT_LINK="$STANDALONE_ROOT/current"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Codex version must use x.y.z format\n' >&2
  exit 65
}
[[ -x "$FETCH_COMMAND" ]] || {
  printf 'verified fetch command is not executable: %s\n' "$FETCH_COMMAND" >&2
  exit 69
}
for command in tar awk grep; do
  command -v "$command" >/dev/null || {
    printf 'missing required command: %s\n' "$command" >&2
    exit 69
  }
done

TEMP_DIR="$(mktemp -d)"
STAGE_DIR="$RELEASES_DIR/.staging.$VERSION-$TARGET.$$"
TEMP_CURRENT="$STANDALONE_ROOT/.current.$$"
TEMP_BIN="$BIN_DIR/.codex.$$"
cleanup() {
  rm -rf "$TEMP_DIR" "$STAGE_DIR"
  rm -f "$TEMP_CURRENT" "$TEMP_BIN"
}
trap cleanup EXIT

ARCHIVE="$TEMP_DIR/codex-package.tar.gz"
"$FETCH_COMMAND" "$PACKAGE_URL" "$PACKAGE_SHA256" "$ARCHIVE"

while IFS= read -r member; do
  normalized="${member#./}"
  [[ -n "$normalized" ]] || continue
  case "$normalized" in
    /*|../*|*/../*|*/..)
      printf 'unsafe archive member: %s\n' "$member" >&2
      exit 66
      ;;
  esac
done < <(tar -tzf "$ARCHIVE")

install -d -m 0755 "$RELEASES_DIR" "$BIN_DIR"
mkdir -p "$STAGE_DIR"
tar -xzf "$ARCHIVE" -C "$STAGE_DIR"
for required in bin/codex bin/codex-code-mode-host codex-path/rg codex-resources/bwrap codex-package.json; do
  [[ -f "$STAGE_DIR/$required" ]] || {
    printf 'Codex package is missing %s\n' "$required" >&2
    exit 66
  }
done
chmod 0755 "$STAGE_DIR/bin/codex" "$STAGE_DIR/bin/codex-code-mode-host" "$STAGE_DIR/codex-path/rg" "$STAGE_DIR/codex-resources/bwrap"
INSTALLED_VERSION="$("$STAGE_DIR/bin/codex" --version | awk '{print $NF}')"
[[ "$INSTALLED_VERSION" == "$VERSION" ]] || {
  printf 'Codex package version mismatch: expected %s, got %s\n' "$VERSION" "$INSTALLED_VERSION" >&2
  exit 66
}
ln -s bin/codex "$STAGE_DIR/codex"

if [[ -e "$RELEASE_DIR" || -L "$RELEASE_DIR" ]]; then
  EXISTING_VERSION="$("$RELEASE_DIR/bin/codex" --version 2>/dev/null | awk '{print $NF}' || true)"
  [[ "$EXISTING_VERSION" == "$VERSION" ]] || {
    printf 'existing release directory has an unexpected version: %s\n' "$RELEASE_DIR" >&2
    exit 73
  }
  rm -rf "$STAGE_DIR"
else
  mv "$STAGE_DIR" "$RELEASE_DIR"
fi

ln -s "$RELEASE_DIR" "$TEMP_CURRENT"
mv -f "$TEMP_CURRENT" "$CURRENT_LINK"
ln -s "$CURRENT_LINK/bin/codex" "$TEMP_BIN"
mv -f "$TEMP_BIN" "$BIN_DIR/codex"
"$BIN_DIR/codex" --version >/dev/null
