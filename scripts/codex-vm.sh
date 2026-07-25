#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
TF_DIR="$ROOT/deployment/prod/tf"
SSH_ALIAS="${CODEX_VM_SSH_ALIAS:-codex-on-vm}"
DRY_RUN=0
USE_COLOR=1
SHELL_SSH_OPENED=0
PREPARATION_CONFIRMED=0
ACTION_CANCELLED=0

if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
  USE_COLOR=0
fi

fail() {
  printf 'Codex VM: %s\n' "$1" >&2
  exit 1
}

paint() {
  local code="$1"
  shift
  if [[ "$USE_COLOR" == "1" ]]; then
    printf '\033[%sm%s\033[0m' "$code" "$*"
  else
    printf '%s' "$*"
  fi
}

headline() {
  printf '\n'
  paint '1;36' "$1"
  printf '\n'
}

stage() {
  printf '\n'
  paint '1;34' "==> $1"
  printf '\n'
}

success() {
  paint '1;32' "Done:"
  printf ' %s\n' "$1"
}

warning() {
  paint '1;33' "Note:"
  printf ' %s\n' "$1"
}

print_command() {
  printf '    $'
  printf ' %q' "$@"
  printf '\n'
}

run_command() {
  if [[ "$DRY_RUN" == "1" ]]; then
    print_command "$@"
    return 0
  fi
  "$@"
}

run_stage() {
  local label="$1"
  local status
  shift
  stage "$label"
  set +e
  "$@"
  status=$?
  set -e
  if [[ "$status" != "0" ]]; then
    paint '1;31' "Failed:"
    printf ' %s (exit %s)\n' "$label" "$status" >&2
    return "$status"
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    success "$label planned"
  else
    success "$label"
  fi
}

extract_embedded_helper() {
  local helper="$1"
  local target="$2"
  local begin_marker="__CODEX_VM_HELPER_BEGIN__ $helper"
  local end_marker="__CODEX_VM_HELPER_END__ $helper"

  awk -v begin_marker="$begin_marker" -v end_marker="$end_marker" '
    $0 == begin_marker {
      found = 1
      capture = 1
      next
    }
    $0 == end_marker {
      if (capture) {
        closed = 1
        exit
      }
    }
    capture {
      print
    }
    END {
      if (!found || !closed) {
        exit 1
      }
    }
  ' "$SELF" >"$target" ||
    fail "could not extract embedded helper: $helper"
}

materialize_helpers() {
  local target="$1"
  local helper

  [[ "$target" == /* ]] || fail "embedded helper target must be an absolute path"
  [[ -d "$ROOT/deployment" ]] || fail "missing deployment tree: $ROOT/deployment"

  if [[ -e "$target" || -L "$target" ]]; then
    [[ -d "$target" && ! -L "$target" ]] ||
      fail "embedded helper target already exists and is not a directory: $target"
    [[ -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
      fail "embedded helper target must be empty: $target"
  else
    mkdir -m 0700 -p "$target"
  fi

  chmod 0700 "$target"
  mkdir -m 0700 -p "$target/scripts" "$target/vm-scripts"
  ln -s "$ROOT/deployment" "$target/deployment"

  for helper in \
    prepare-machine.sh \
    codex-pair.sh \
    dot-codex-bootstrap.sh \
    remote-control-recover.sh \
    ssh-open.sh \
    ssh-close.sh \
    workspace-open.sh \
    workspace-close.sh; do
    extract_embedded_helper "$helper" "$target/scripts/$helper"
  done

  for helper in \
    ensure-codex-remote-control.sh \
    ensure-ssh-keys.sh \
    fetch-verified-artifact.sh \
    install-verified-codex.sh \
    prepare-codex-vm.sh \
    prepare-persistent-codex-home.sh; do
    extract_embedded_helper "$helper" "$target/vm-scripts/$helper"
  done

  chmod 0700 "$target/scripts/"*.sh
  chmod 0700 "$target/vm-scripts/"*.sh
}

run_embedded_payload() {
  local payload="$1"
  local runtime_root
  shift

  case "$payload" in
    ensure-codex-remote-control.sh) ;;
    ensure-ssh-keys.sh) ;;
    fetch-verified-artifact.sh) ;;
    install-verified-codex.sh) ;;
    prepare-codex-vm.sh) ;;
    prepare-persistent-codex-home.sh) ;;
    *) fail "unknown embedded VM payload: $payload" ;;
  esac

  (
    set -euo pipefail
    umask 077
    runtime_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-vm.XXXXXX")"
    trap 'rm -rf "$runtime_root"' EXIT INT TERM
    materialize_helpers "$runtime_root"
    "$runtime_root/vm-scripts/$payload" "$@"
  )
}

run_helper() {
  local helper="$1"
  local runtime_root
  shift

  case "$helper" in
    prepare-machine.sh) ;;
    codex-pair.sh) ;;
    dot-codex-bootstrap.sh) ;;
    remote-control-recover.sh) ;;
    ssh-open.sh) ;;
    ssh-close.sh) ;;
    workspace-open.sh) ;;
    workspace-close.sh) ;;
    *) fail "unknown embedded helper: $helper" ;;
  esac

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    embedded helper: %s' "$helper"
    if [[ $# -gt 0 ]]; then
      printf ' %q' "$@"
    fi
    printf '\n'
    return 0
  fi

  if [[ "${CODEX_VM_TEST_MODE:-0}" == "1" && -n "${CODEX_VM_TEST_HELPER_DIR:-}" ]]; then
    [[ "$CODEX_VM_TEST_HELPER_DIR" == /* ]] ||
      fail "CODEX_VM_TEST_HELPER_DIR must be an absolute path"
    [[ -x "$CODEX_VM_TEST_HELPER_DIR/$helper" ]] ||
      fail "missing executable test helper: $CODEX_VM_TEST_HELPER_DIR/$helper"
    "$CODEX_VM_TEST_HELPER_DIR/$helper" "$@"
    return
  fi

  (
    set -euo pipefail
    umask 077
    runtime_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-vm.XXXXXX")"
    trap 'rm -rf "$runtime_root"' EXIT INT TERM
    materialize_helpers "$runtime_root"
    "$runtime_root/scripts/$helper" "$@"
  )
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "this command is for macOS"
}

require_commands() {
  local command
  for command in "$@"; do
    command -v "$command" >/dev/null || fail "missing required command: $command"
  done
}

print_usage() {
  cat <<'EOF'
Codex VM

Usage:
  scripts/codex-vm.sh [--dry-run] [--no-color] <command> [arguments]
  scripts/codex-vm.sh

Commands:
  setup                     Set up or repair Codex after manual Terraform apply
  pair                      Sign in and pair a device
  dot-codex                 Clone or update dot-codex from GitHub
  shell                     Open a temporary interactive SSH shell, then close access
  ssh-close                 Close temporary SSH
  workspace-open [PATH]     Mount projects, or one absolute remote path, on this Mac
  workspace-close           Unmount the workspace and close temporary SSH
  status                    Read VM, SSH, trust, and workspace status
  menu                      Open the interactive menu
  help                      Show this help

Options:
  --dry-run                 Print mutating commands without running them
  --no-color                Disable ANSI colors

Examples:
  scripts/codex-vm.sh setup
  scripts/codex-vm.sh pair
  scripts/codex-vm.sh dot-codex
  scripts/codex-vm.sh workspace-open /home/azureadmin
  scripts/codex-vm.sh status

If preparation is required, interactive commands ask before running setup.
Non-interactive commands stop and instruct you to run setup explicitly.
EOF
}

delegate_no_args() {
  local label="$1"
  local helper="$2"
  shift 2
  [[ $# -eq 0 ]] || fail "$label accepts no positional arguments"
  headline "$label"
  run_stage "$label" run_helper "$helper"
}

delegate_prepared_no_args() {
  local label="$1"
  local helper="$2"
  shift 2
  [[ $# -eq 0 ]] || fail "$label accepts no positional arguments"
  ensure_vm_prepared || return $?
  [[ "$ACTION_CANCELLED" == "0" ]] || return 0
  headline "$label"
  run_stage "$label" run_helper "$helper"
}

setup_machine() {
  [[ $# -eq 0 ]] || fail "Set up or repair Codex on the VM accepts no positional arguments"
  headline "Set up or repair Codex on the VM"
  run_stage "Set up or repair Codex on the VM" run_helper prepare-machine.sh || return $?
  PREPARATION_CONFIRMED=1
}

workspace_open() {
  [[ $# -le 1 ]] || fail "workspace-open accepts at most one remote path"
  if [[ $# -eq 1 && "$1" != /* ]]; then
    fail "workspace-open requires an absolute remote path"
  fi
  ensure_vm_prepared || return $?
  [[ "$ACTION_CANCELLED" == "0" ]] || return 0
  headline "Open workspace mount"
  run_stage "Open workspace mount" run_helper workspace-open.sh "$@"
}

shell_cleanup() {
  local status="$1"
  local close_status=0
  trap - EXIT
  set +e
  if [[ "$SHELL_SSH_OPENED" == "1" ]]; then
    run_helper ssh-close.sh
    close_status=$?
    SHELL_SSH_OPENED=0
  fi
  if [[ "$close_status" != "0" ]]; then
    warning "Temporary SSH cleanup failed; run scripts/codex-vm.sh ssh-close."
  fi
  exit "$status"
}

temporary_shell() {
  [[ $# -eq 0 ]] || fail "shell accepts no positional arguments"
  [[ -n "$SSH_ALIAS" && "$SSH_ALIAS" != -* && "$SSH_ALIAS" != *[[:space:]]* ]] ||
    fail "CODEX_VM_SSH_ALIAS is invalid"

  if [[ "$DRY_RUN" != "1" ]]; then
    require_commands ssh
  fi
  ensure_vm_prepared || return $?
  [[ "$ACTION_CANCELLED" == "0" ]] || return 0
  headline "Temporary SSH shell"
  if [[ "$DRY_RUN" == "1" ]]; then
    run_stage "Normalize temporary SSH state" run_helper ssh-close.sh
    run_stage "Open restricted temporary SSH" run_helper ssh-open.sh
    run_stage "Connect to $SSH_ALIAS" run_command ssh "$SSH_ALIAS"
    run_stage "Close temporary SSH" run_helper ssh-close.sh
    return 0
  fi

  run_stage "Normalize temporary SSH state" run_helper ssh-close.sh
  run_stage "Open restricted temporary SSH" run_helper ssh-open.sh
  SHELL_SSH_OPENED=1
  trap 'shell_cleanup $?' EXIT
  trap 'exit 130' INT TERM

  run_stage "Connect to $SSH_ALIAS" run_command ssh "$SSH_ALIAS"
  run_stage "Close temporary SSH" run_helper ssh-close.sh
  SHELL_SSH_OPENED=0
  trap - EXIT INT TERM
  success "Interactive SSH ended and temporary access is closed"
}

read_connection() {
  local connection
  connection="$(terraform "-chdir=$TF_DIR" output -json connection)"
  CONNECTION="$connection" python3 - <<'PY'
import json
import os
import re

value = json.loads(os.environ["CONNECTION"])
keys = (
    "subscription_id",
    "resource_group_name",
    "network_security_group_name",
    "temporary_ssh_rule_name",
    "vm_name",
    "ssh_alias",
    "ssh_host_config_path",
    "ssh_known_hosts_path",
    "local_mount_path",
)
patterns = (
    r"[0-9a-fA-F-]{36}",
    r"[A-Za-z0-9._()/-]{1,90}",
    r"[A-Za-z0-9._-]{1,80}",
    r"[A-Za-z0-9._-]{1,80}",
    r"[A-Za-z0-9-]{1,64}",
    r"[A-Za-z0-9._-]{1,64}",
    r"/[^\t\r\n]+",
    r"/[^\t\r\n]+",
    r"/[^\t\r\n]+",
)
fields = [str(value[key]) for key in keys]
for key, field, pattern in zip(keys, fields, patterns):
    if re.fullmatch(pattern, field) is None:
        raise SystemExit(f"Terraform connection output contains an unsafe {key}")
print("\t".join(fields))
PY
}

read_preparation_target() {
  local connection
  connection="$(terraform "-chdir=$TF_DIR" output -json connection)" ||
    fail "could not read Terraform connection output; run terraform apply first"
  CONNECTION="$connection" python3 - <<'PY'
import json
import os
import re

try:
    value = json.loads(os.environ["CONNECTION"])
except (json.JSONDecodeError, TypeError) as error:
    raise SystemExit(f"Terraform connection output is not valid JSON: {error}")

keys = (
    "subscription_id",
    "resource_group_name",
    "vm_name",
    "workspace_mount_path",
    "codex_version",
)
patterns = (
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    r"[A-Za-z0-9._()/-]{1,90}",
    r"[A-Za-z0-9-]{1,64}",
    r"/[^\t\r\n]+",
    r"[0-9]+\.[0-9]+\.[0-9]+",
)
try:
    fields = [str(value[key]) for key in keys]
except (KeyError, TypeError) as error:
    raise SystemExit(f"Terraform connection output is missing {error}")
for key, field, pattern in zip(keys, fields, patterns):
    if re.fullmatch(pattern, field) is None:
        raise SystemExit(f"Terraform connection output contains an unsafe {key}")
print("\t".join(fields))
PY
}

vm_is_prepared() {
  local values subscription_id resource_group vm_name workspace_mount codex_version
  local active_subscription check_script response

  require_commands terraform az python3
  values="$(read_preparation_target)" || return $?
  IFS=$'\t' read -r \
    subscription_id resource_group vm_name workspace_mount codex_version <<<"$values"

  active_subscription="$(az account show --query id --output tsv)" ||
    fail "could not read the active Azure subscription"
  [[ "$active_subscription" == "$subscription_id" ]] ||
    fail "Azure CLI is using subscription $active_subscription, expected $subscription_id"

  check_script="$(
    CODEX_VERSION="$codex_version" WORKSPACE_MOUNT="$workspace_mount" python3 - <<'PY'
import os
import shlex

version = shlex.quote(f"codex_version={os.environ['CODEX_VERSION']}")
mount = shlex.quote(f"workspace_mount={os.environ['WORKSPACE_MOUNT']}")
print("marker=/var/lib/codex-on-vm/prepared")
print(
    'if test -r "$marker"'
    f" && grep -Fqx -- {version} \"$marker\""
    f" && grep -Fqx -- {mount} \"$marker\"; then"
)
print("  printf 'CODEX_ON_VM_PREPARED=1\\n'")
print("fi")
PY
  )"

  if ! response="$(az vm run-command invoke \
    --subscription "$subscription_id" \
    --resource-group "$resource_group" \
    --name "$vm_name" \
    --command-id RunShellScript \
    --scripts "$check_script" \
    --output json \
    --only-show-errors)"; then
    return 1
  fi

  RESPONSE="$response" python3 - <<'PY'
import json
import os

try:
    value = json.loads(os.environ["RESPONSE"])
except (json.JSONDecodeError, TypeError):
    raise SystemExit(1)

messages = []
for item in value.get("value", []):
    if isinstance(item, dict):
        messages.append(str(item.get("message", "")))
if any(
    line.strip() == "CODEX_ON_VM_PREPARED=1"
    for message in messages
    for line in message.splitlines()
):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

ensure_vm_prepared() {
  local answer
  ACTION_CANCELLED=0

  if [[ "$PREPARATION_CONFIRMED" == "1" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    Preparation gate: setup requires confirmation when the current VM marker is missing or stale.\n'
    PREPARATION_CONFIRMED=1
    return 0
  fi

  if vm_is_prepared; then
    PREPARATION_CONFIRMED=1
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    fail "VM setup is required before this command; run scripts/codex-vm.sh setup first"
  fi

  headline "VM setup required"
  printf 'Codex is not set up for the current VM configuration.\n'
  printf 'Run setup now? [y/N] '
  if ! IFS= read -r answer </dev/tty; then
    printf '\n'
    warning "Action cancelled."
    ACTION_CANCELLED=1
    return 0
  fi
  case "$answer" in
    y | Y | [yY][eE][sS])
      setup_machine || return $?
      ;;
    *)
      warning "Action cancelled."
      ACTION_CANCELLED=1
      ;;
  esac
}

status_report() {
  local values active_subscription vm_status power_state agent_state ssh_state
  local subscription_id resource_group nsg_name rule_name vm_name
  local ssh_alias ssh_config known_hosts local_mount
  [[ $# -eq 0 ]] || fail "status accepts no positional arguments"
  require_commands terraform az python3 mount

  headline "Codex VM status"
  values="$(read_connection)"
  IFS=$'\t' read -r \
    subscription_id resource_group nsg_name rule_name vm_name ssh_alias \
    ssh_config known_hosts local_mount <<<"$values"

  active_subscription="$(az account show --query id --output tsv)"
  [[ "$active_subscription" == "$subscription_id" ]] ||
    fail "Azure CLI is using subscription $active_subscription, expected $subscription_id"

  vm_status="$(az vm get-instance-view \
    --subscription "$subscription_id" \
    --resource-group "$resource_group" \
    --name "$vm_name" \
    --query "[instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0], instanceView.vmAgent.statuses[0].code]" \
    --output tsv \
    --only-show-errors)"
  IFS=$'\t' read -r power_state agent_state <<<"$vm_status"

  ssh_state="closed"
  if az network nsg rule show \
    --subscription "$subscription_id" \
    --resource-group "$resource_group" \
    --nsg-name "$nsg_name" \
    --name "$rule_name" \
    --only-show-errors >/dev/null 2>&1; then
    ssh_state="OPEN"
  fi

  printf '  %-22s %s\n' "VM" "$vm_name"
  printf '  %-22s %s\n' "Power" "${power_state:-unknown}"
  printf '  %-22s %s\n' "VM agent" "${agent_state:-unknown}"
  printf '  %-22s %s\n' "Temporary SSH" "$ssh_state"
  printf '  %-22s %s\n' "SSH alias" "$ssh_alias"
  printf '  %-22s %s\n' "SSH config" "$([[ -f "$ssh_config" ]] && printf ready || printf missing)"
  printf '  %-22s %s\n' "Known hosts" "$([[ -f "$known_hosts" ]] && printf ready || printf missing)"
  if mount | grep -F " on $local_mount " >/dev/null; then
    printf '  %-22s %s\n' "Workspace mount" "mounted at $local_mount"
  else
    printf '  %-22s %s\n' "Workspace mount" "not mounted ($local_mount)"
  fi
}

show_menu() {
  local choice action action_status
  [[ $# -eq 0 ]] || fail "menu accepts no positional arguments"
  [[ -t 0 && -t 1 ]] || fail "the interactive menu requires a terminal; run help for explicit commands"

  while true; do
    printf '\033c'
    headline "Codex VM operator console"
    printf '\n  1) Set up or repair Codex on the VM\n'
    printf '  2) Sign in and pair a device\n'
    printf '  3) Clone or update dot-codex from GitHub\n'
    printf '  4) Open a temporary SSH shell\n'
    printf '  5) Close temporary SSH\n'
    printf '  6) Mount VM files on this Mac\n'
    printf '  7) Unmount VM files\n'
    printf '  8) Show status\n'
    printf '  0) Exit\n\n'
    printf 'Choose an action: '
    IFS= read -r choice </dev/tty || return 0
    case "$choice" in
      1) action=setup ;;
      2) action=pair ;;
      3) action=dot-codex ;;
      4) action=shell ;;
      5) action=ssh-close ;;
      6) action=workspace-open ;;
      7) action=workspace-close ;;
      8) action=status ;;
      0) return 0 ;;
      *)
        warning "Unknown selection: $choice"
        printf 'Press Enter to continue...'
        IFS= read -r _unused </dev/tty || return 0
        continue
        ;;
    esac

    set +e
    (set -e; dispatch "$action")
    action_status=$?
    set -e
    if [[ "$action_status" != "0" ]]; then
      paint '1;31' "Action failed."
      printf ' Review the output above; the menu will remain available.\n'
    fi
    printf '\nPress Enter to continue...'
    IFS= read -r _unused </dev/tty || return 0
  done
}

dispatch() {
  local command_name="$1"
  shift
  case "$command_name" in
    help)
      [[ $# -eq 0 ]] || fail "help accepts no positional arguments"
      print_usage
      return 0
      ;;
    setup | pair | dot-codex | shell | ssh-close | workspace-open | workspace-close | status | menu)
      ;;
    *) fail "unknown command '$command_name'; run scripts/codex-vm.sh help" ;;
  esac

  require_macos
  case "$command_name" in
    setup) setup_machine "$@" ;;
    pair) delegate_prepared_no_args "Sign in and pair a device" codex-pair.sh "$@" ;;
    dot-codex) delegate_prepared_no_args "Clone or update dot-codex from GitHub" dot-codex-bootstrap.sh "$@" ;;
    shell) temporary_shell "$@" ;;
    ssh-close) delegate_no_args "Close temporary SSH" ssh-close.sh "$@" ;;
    workspace-open) workspace_open "$@" ;;
    workspace-close) delegate_no_args "Close workspace mount" workspace-close.sh "$@" ;;
    status) status_report "$@" ;;
    menu) show_menu "$@" ;;
  esac
}

main() {
  local command_name

  if [[ "${1:-}" == "__extract-helpers" ]]; then
    [[ "${CODEX_VM_TEST_MODE:-0}" == "1" ]] ||
      fail "__extract-helpers is available only in test mode"
    [[ $# -eq 2 ]] ||
      fail "__extract-helpers requires one absolute target directory"
    materialize_helpers "$2"
    return 0
  fi

  if [[ "${1:-}" == "__terraform-ensure-ssh-keys" ]]; then
    [[ $# -eq 1 ]] ||
      fail "__terraform-ensure-ssh-keys accepts no positional arguments"
    run_embedded_payload ensure-ssh-keys.sh
    return 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --no-color) USE_COLOR=0 ;;
      --help | -h)
        print_usage
        return 0
        ;;
      --) shift; break ;;
      -*) fail "unknown option '$1'; run scripts/codex-vm.sh help" ;;
      *) break ;;
    esac
    shift
  done

  if [[ $# -eq 0 ]]; then
    command_name=menu
  else
    command_name="$1"
    shift
  fi
  dispatch "$command_name" "$@"
}

main "$@"
exit $?

__CODEX_VM_HELPER_BEGIN__ prepare-machine.sh
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
VM_SCRIPT_DIR="$ROOT/vm-scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'Machine preparation failed: %s\n' "$1" >&2
  exit 1
}

write_private_file() {
  local target="$1"
  local temporary
  mkdir -p "$(dirname "$target")"
  temporary="$(mktemp "$(dirname "$target")/.codex-on-vm.XXXXXX")"
  cat >"$temporary"
  chmod 0600 "$temporary"
  mv -f "$temporary" "$target"
}

[[ $# -eq 0 ]] || fail "this command accepts no positional arguments"
[[ "$(uname -s)" == "Darwin" ]] || fail "this helper is for macOS"
for command in az python3 terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done

for script in \
  fetch-verified-artifact.sh \
  install-verified-codex.sh \
  prepare-persistent-codex-home.sh \
  ensure-codex-remote-control.sh \
  prepare-codex-vm.sh; do
  [[ -r "$VM_SCRIPT_DIR/$script" ]] || fail "missing VM preparation script: $VM_SCRIPT_DIR/$script"
done

CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
IFS=$'\t' read -r \
  SUBSCRIPTION_ID \
  RESOURCE_GROUP \
  VM_NAME \
  SSH_ALIAS \
  SSH_FQDN \
  SSH_USERNAME \
  WORKSPACE_MOUNT_PATH \
  WORKSPACE_DISK_LUN \
  CODEX_VERSION \
  CODEX_PACKAGE_URL \
  CODEX_PACKAGE_SHA256 \
  MAC_PRIVATE_KEY_PATH \
  SSH_HOST_CONFIG_PATH \
  SSH_KNOWN_HOSTS_PATH <<<"$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os
import re

value = json.loads(os.environ["CONNECTION"])
keys = (
    "subscription_id",
    "resource_group_name",
    "vm_name",
    "ssh_alias",
    "ssh_fqdn",
    "ssh_username",
    "workspace_mount_path",
    "workspace_disk_lun",
    "codex_version",
    "codex_package_url",
    "codex_package_sha256",
    "mac_private_key_path",
    "ssh_host_config_path",
    "ssh_known_hosts_path",
)
fields = [str(value[key]) for key in keys]
patterns = (
    r"[0-9a-fA-F-]{36}",
    r"[A-Za-z0-9._()/-]{1,90}",
    r"[A-Za-z0-9-]{1,64}",
    r"[A-Za-z0-9._-]{1,64}",
    r"[A-Za-z0-9.-]{1,253}",
    r"[a-z_][a-z0-9_-]{0,31}",
    r"/[^\t\r\n]+",
    r"[0-9]+",
    r"[0-9]+\.[0-9]+\.[0-9]+",
    r"https://[^\t\r\n]+",
    r"[0-9a-f]{64}",
    r"/[^\t\r\n]+",
    r"/[^\t\r\n]+",
    r"/[^\t\r\n]+",
)
for key, field, pattern in zip(keys, fields, patterns):
    if re.fullmatch(pattern, field) is None:
        raise SystemExit(f"Terraform connection output contains an unsafe {key}")
print("\t".join(fields))
PY
)"

[[ "$(az account show --query id --output tsv)" == "$SUBSCRIPTION_ID" ]] ||
  fail "Azure CLI is using a different subscription"

printf 'Preparing VM %s in resource group %s from this Mac.\n' "$VM_NAME" "$RESOURCE_GROUP"
agent_ready=0
for _attempt in $(seq 1 60); do
  if [[ "$(az vm get-instance-view \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --query "instanceView.vmAgent.statuses[?code=='ProvisioningState/succeeded'].code | [0]" \
    --output tsv \
    --only-show-errors 2>/dev/null || true)" == "ProvisioningState/succeeded" ]]; then
    agent_ready=1
    break
  fi
  sleep 10
done
[[ "$agent_ready" == "1" ]] || fail "Azure VM agent did not become ready"

REMOTE_PAYLOAD="$TMP/prepare-codex-vm-payload.sh"
VM_SCRIPT_DIR="$VM_SCRIPT_DIR" \
  SSH_USERNAME="$SSH_USERNAME" \
  WORKSPACE_MOUNT_PATH="$WORKSPACE_MOUNT_PATH" \
  WORKSPACE_DISK_LUN="$WORKSPACE_DISK_LUN" \
  CODEX_VERSION="$CODEX_VERSION" \
  CODEX_PACKAGE_URL="$CODEX_PACKAGE_URL" \
  CODEX_PACKAGE_SHA256="$CODEX_PACKAGE_SHA256" \
  python3 >"$REMOTE_PAYLOAD" <<'PY'
import base64
import hashlib
import os
import pathlib
import shlex

source_dir = pathlib.Path(os.environ["VM_SCRIPT_DIR"])
files = (
    ("fetch-verified-artifact.sh", "/usr/local/sbin/fetch-verified-artifact"),
    ("install-verified-codex.sh", "/usr/local/sbin/install-verified-codex"),
    ("prepare-persistent-codex-home.sh", "/usr/local/sbin/prepare-persistent-codex-home"),
    ("ensure-codex-remote-control.sh", "/usr/local/sbin/ensure-codex-remote-control"),
    ("prepare-codex-vm.sh", "/usr/local/sbin/prepare-codex-vm"),
)

print("""#!/usr/bin/env bash
set -euo pipefail
VM_ROOT="${CODEX_VM_ROOT:-}"
install_checked() {
  local logical_target="$1"
  local expected_sha="$2"
  local encoded="$3"
  local target="${VM_ROOT}${logical_target}"
  local temporary actual_sha
  temporary="$(mktemp)"
  printf '%s' "$encoded" | base64 --decode >"$temporary"
  actual_sha="$(sha256sum "$temporary" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || {
    printf 'VM preparation payload checksum mismatch for %s\\n' "$logical_target" >&2
    exit 1
  }
  install -d -m 0755 "$(dirname "$target")"
  if [[ ! -f "$target" ]] || ! cmp -s "$temporary" "$target"; then
    if [[ "${CODEX_VM_TEST_MODE:-0}" == "1" ]]; then
      install -m 0755 "$temporary" "$target"
    else
      install -o root -g root -m 0755 "$temporary" "$target"
    fi
  fi
  cmp -s "$temporary" "$target" || {
    printf 'VM preparation payload reconciliation failed for %s\\n' "$logical_target" >&2
    exit 1
  }
  rm -f "$temporary"
}
""")

for source_name, target in files:
    content = (source_dir / source_name).read_bytes()
    digest = hashlib.sha256(content).hexdigest()
    encoded = base64.b64encode(content).decode("ascii")
    print(f"install_checked {shlex.quote(target)} {shlex.quote(digest)} {shlex.quote(encoded)}")

arguments = (
    os.environ["SSH_USERNAME"],
    os.environ["WORKSPACE_MOUNT_PATH"],
    os.environ["WORKSPACE_DISK_LUN"],
    os.environ["CODEX_VERSION"],
    os.environ["CODEX_PACKAGE_URL"],
    os.environ["CODEX_PACKAGE_SHA256"],
)
quoted = " ".join(shlex.quote(value) for value in arguments)
print(f'exec "$VM_ROOT/usr/local/sbin/prepare-codex-vm" {quoted}')
PY
chmod 0600 "$REMOTE_PAYLOAD"

RUN_RESPONSE="$TMP/run-command.json"
if ! az vm run-command invoke \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts @"$REMOTE_PAYLOAD" \
  --output json \
  --only-show-errors >"$RUN_RESPONSE"; then
  fail "Azure Run Command preparation failed"
fi

if ! SSH_HOST_PUBLIC_KEY="$(python3 - "$RUN_RESPONSE" <<'PY'
import json
import pathlib
import re
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
messages = "\n".join(str(item.get("message", "")) for item in value.get("value", []))
if "CODEX_ON_VM_PREPARED=1" not in messages:
    raise SystemExit("remote preparation readiness marker is missing")
match = re.search(r"^SSH_HOST_PUBLIC_KEY=(ssh-ed25519 [A-Za-z0-9+/=]+)$", messages, re.MULTILINE)
if match is None:
    raise SystemExit("remote Ed25519 host key read-back is missing")
print(match.group(1))
PY
  )"; then
  python3 - "$RUN_RESPONSE" <<'PY' >&2
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
messages = "\n".join(str(item.get("message", "")) for item in value.get("value", []))
if messages:
    print("Azure Run Command output (bounded tail):")
    print(messages[-4096:])
PY
  fail "remote preparation read-back failed"
fi

printf '%s %s\n' "$SSH_FQDN" "$SSH_HOST_PUBLIC_KEY" |
  write_private_file "$SSH_KNOWN_HOSTS_PATH"
cat <<EOF | write_private_file "$SSH_HOST_CONFIG_PATH"
Host $SSH_ALIAS
  HostName $SSH_FQDN
  User $SSH_USERNAME
  IdentityFile $MAC_PRIVATE_KEY_PATH
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $SSH_KNOWN_HOSTS_PATH
EOF

printf 'Machine preparation completed through Azure Run Command.\n'
printf '  VM: %s\n' "$VM_NAME"
printf '  Projects: %s\n' "$WORKSPACE_MOUNT_PATH"
printf '  SSH host config: %s\n' "$SSH_HOST_CONFIG_PATH"
printf '  Next: scripts/codex-vm.sh pair\n'
__CODEX_VM_HELPER_END__ prepare-machine.sh

__CODEX_VM_HELPER_BEGIN__ codex-pair.sh
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_ALIAS="${CODEX_VM_SSH_ALIAS:-codex-on-vm}"
SSH_OPENED=0

fail() {
  printf 'Codex pairing failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  local status=$?
  if [[ "$SSH_OPENED" == "1" ]]; then
    "$ROOT/scripts/ssh-close.sh" >/dev/null 2>&1 || {
      printf 'Codex pairing cleanup warning: temporary SSH may remain open; run scripts/codex-vm.sh ssh-close\n' >&2
    }
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

[[ $# -eq 0 ]] || fail "this command accepts no positional arguments"
[[ "$(uname -s)" == "Darwin" ]] || fail "this helper is for macOS"
[[ -n "$SSH_ALIAS" && "$SSH_ALIAS" != -* && "$SSH_ALIAS" != *[[:space:]]* ]] ||
  fail "CODEX_VM_SSH_ALIAS is invalid"
command -v ssh >/dev/null || fail "missing required command: ssh"
[[ -x "$ROOT/scripts/ssh-open.sh" && -x "$ROOT/scripts/ssh-close.sh" ]] ||
  fail "temporary SSH helpers are unavailable"

"$ROOT/scripts/ssh-close.sh"
"$ROOT/scripts/ssh-open.sh"
SSH_OPENED=1

REMOTE_AUTH='CODEX_BIN="$HOME/.codex/packages/standalone/current/codex"; test -x "$CODEX_BIN" || { printf "Managed Codex is missing; run scripts/codex-vm.sh setup locally first.\n" >&2; exit 1; }; "$CODEX_BIN" login status >/dev/null 2>&1 || exec "$CODEX_BIN" login --device-auth'
ssh -t "$SSH_ALIAS" "$REMOTE_AUTH"

REMOTE_PAIR='CODEX_BIN="$HOME/.codex/packages/standalone/current/codex"; "$CODEX_BIN" remote-control start; "$CODEX_BIN" remote-control pair'
ssh "$SSH_ALIAS" "$REMOTE_PAIR"

"$ROOT/scripts/ssh-close.sh"
SSH_OPENED=0
printf 'Codex authentication and pairing were launched from this Mac; temporary SSH is closed.\n'
__CODEX_VM_HELPER_END__ codex-pair.sh

__CODEX_VM_HELPER_BEGIN__ dot-codex-bootstrap.sh
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_ALIAS="${CODEX_VM_SSH_ALIAS:-codex-on-vm}"
REPOSITORY_URL="${DOT_CODEX_REPOSITORY_URL:-https://github.com/marcocello/dot-codex}"
REMOTE_DIR="${DOT_CODEX_REMOTE_DIR:-}"
REMOTE_RECOVERY_HELPER="${DOT_CODEX_REMOTE_RECOVERY_HELPER:-/usr/local/sbin/ensure-codex-remote-control}"
REMOTE_CONTROL_RETRY_SECONDS="${DOT_CODEX_REMOTE_CONTROL_RETRY_SECONDS:-2}"
SSH_OPENED=0
STEP_NUMBER=0
CURRENT_PHASE="initialization"

fail() {
  printf 'Dot Codex bootstrap failed: %s\n' "$1" >&2
  exit 1
}

step() {
  STEP_NUMBER=$((STEP_NUMBER + 1))
  CURRENT_PHASE="$1"
  printf '\n[%d/8] %s\n' "$STEP_NUMBER" "$CURRENT_PHASE"
}

note() {
  printf '  - %s\n' "$1"
}

cleanup_on_exit() {
  local status=$?
  local close_status=0
  trap - EXIT
  set +e
  if [[ "$SSH_OPENED" == "1" ]]; then
    printf '\n[cleanup] Closing temporary SSH after failure or interruption.\n'
    "$ROOT/scripts/ssh-close.sh"
    close_status=$?
  fi
  if [[ "$status" == "0" && "$close_status" != "0" ]]; then
    status=$close_status
  elif [[ "$status" != "0" && "$close_status" != "0" ]]; then
    printf 'Dot Codex bootstrap cleanup warning: temporary SSH could not be closed; run scripts/codex-vm.sh ssh-close\n' >&2
  fi
  if [[ "$status" != "0" ]]; then
    printf '\n[FAILED] %s\n' "$CURRENT_PHASE" >&2
  fi
  exit "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

step "Validate local inputs and helper availability"
[[ "$#" == "0" ]] || fail "this command accepts no positional arguments"
[[ "$(uname -s)" == "Darwin" ]] || fail "this helper is for macOS"
[[ -n "$REPOSITORY_URL" ]] || fail "DOT_CODEX_REPOSITORY_URL must not be empty"
[[ "$REPOSITORY_URL" != *$'\n'* && "$REPOSITORY_URL" != *$'\r'* && "$REPOSITORY_URL" != *$'\t'* ]] || fail "repository URL must not contain control characters"
[[ -n "$SSH_ALIAS" && "$SSH_ALIAS" != -* ]] || fail "CODEX_VM_SSH_ALIAS is invalid"
[[ "$SSH_ALIAS" != *$'\n'* && "$SSH_ALIAS" != *$'\r'* && "$SSH_ALIAS" != *$'\t'* && "$SSH_ALIAS" != *' '* ]] || fail "SSH alias must not contain whitespace"
[[ "$REMOTE_RECOVERY_HELPER" == /* ]] || fail "DOT_CODEX_REMOTE_RECOVERY_HELPER must be an absolute remote path"
[[ "$REMOTE_RECOVERY_HELPER" != *$'\n'* && "$REMOTE_RECOVERY_HELPER" != *$'\r'* && "$REMOTE_RECOVERY_HELPER" != *$'\t'* ]] || fail "remote recovery-helper path must not contain control characters"
[[ "$REMOTE_CONTROL_RETRY_SECONDS" =~ ^[0-9]+$ ]] || fail "DOT_CODEX_REMOTE_CONTROL_RETRY_SECONDS must be an integer"
((REMOTE_CONTROL_RETRY_SECONDS <= 30)) || fail "DOT_CODEX_REMOTE_CONTROL_RETRY_SECONDS must be between 0 and 30"
if [[ -n "$REMOTE_DIR" ]]; then
  [[ "$REMOTE_DIR" == /* ]] || fail "DOT_CODEX_REMOTE_DIR must be an absolute remote path"
  [[ "$REMOTE_DIR" != *$'\n'* && "$REMOTE_DIR" != *$'\r'* && "$REMOTE_DIR" != *$'\t'* ]] || fail "remote path must not contain control characters"
fi

command -v ssh >/dev/null || fail "missing required command: ssh"
[[ -x "$ROOT/scripts/ssh-open.sh" ]] || fail "missing SSH open helper"
[[ -x "$ROOT/scripts/ssh-close.sh" ]] || fail "missing SSH close helper"
[[ -x "$ROOT/scripts/remote-control-recover.sh" ]] || fail "missing Remote Control recovery helper"
note "Repository: $REPOSITORY_URL"
note "VM SSH alias: $SSH_ALIAS"
note "Remote clone: ${REMOTE_DIR:-\$HOME/projects/dot-codex}"
note "Local validation passed."

step "Normalize temporary SSH state"
note "Closing any retained state or deterministic provider rule before opening a fresh session."
"$ROOT/scripts/ssh-close.sh"
note "Temporary SSH state is clean."

step "Open restricted temporary SSH"
"$ROOT/scripts/ssh-open.sh"
SSH_OPENED=1
note "Restricted SSH is open for this operation."

step "Reconcile and repair current Remote Control"
note "Checking Codex login before any daemon recovery."
printf -v REMOTE_PREFLIGHT_COMMAND 'bash -s -- %q' "packages/standalone/current/codex"
ssh "$SSH_ALIAS" "$REMOTE_PREFLIGHT_COMMAND" <<'REMOTE_PREFLIGHT'
set -euo pipefail
MANAGED_RELATIVE_PATH="$1"
CODEX_BIN="$HOME/.codex/$MANAGED_RELATIVE_PATH"
[[ -x "$CODEX_BIN" ]] || {
  printf 'Remote bootstrap preflight failed: managed Codex is missing at %s\n' "$CODEX_BIN" >&2
  exit 1
}
"$CODEX_BIN" login status >/dev/null 2>&1 || {
  printf 'Remote bootstrap preflight failed: Codex is not logged in; run scripts/codex-vm.sh pair from the Mac checkout\n' >&2
  exit 1
}
printf '  [remote] Codex login is ready.\n'
REMOTE_PREFLIGHT
note "Using Azure Run Command to install the checked-in recovery helper when needed."
if "$ROOT/scripts/remote-control-recover.sh"; then
  note "Pre-migration Remote Control recovery completed."
else
  note "Pre-migration recovery did not complete; the SSH phase will diagnose login and retry safely."
fi

step "Bootstrap or repair dot-codex on the VM"
printf -v REMOTE_COMMAND \
  'bash -s -- %q %q %q %q' \
  "$REPOSITORY_URL" \
  "$REMOTE_DIR" \
  "$REMOTE_RECOVERY_HELPER" \
  "$REMOTE_CONTROL_RETRY_SECONDS"
ssh "$SSH_ALIAS" "$REMOTE_COMMAND" <<'REMOTE_SCRIPT'
set -euo pipefail

REPOSITORY_URL="$1"
REMOTE_DIR_OVERRIDE="$2"
RECOVERY_HELPER="$3"
RETRY_SECONDS="$4"
DOT_CODEX_DIR="${REMOTE_DIR_OVERRIDE:-$HOME/projects/dot-codex}"
CODEX_LINK="$HOME/.codex"
MANAGED_RELATIVE_PATH="packages/standalone/current/codex"
BACKUP_PATH=""
MOVED_OLD_CODEX=0
CREATED_LINK=0
DAEMON_STOPPED=0

fail() {
  printf 'Remote Dot Codex bootstrap failed: %s\n' "$1" >&2
  exit 1
}

remote_note() {
  printf '  [remote] %s\n' "$1"
}

remote_control_connected_once() {
  local attempt="$1"
  local bin output status timed_out environment_id
  bin="$CODEX_LINK/$MANAGED_RELATIVE_PATH"
  if ! output="$("$bin" remote-control start --json 2>&1)"; then
    remote_note "Remote Control check $attempt: start command failed."
    return 1
  fi
  status="$(jq -r '.status // "unknown"' <<<"$output" 2>/dev/null || printf 'invalid-json')"
  timed_out="$(jq -r 'if has("timedOut") then (.timedOut | tostring) else "unknown" end' <<<"$output" 2>/dev/null || printf 'invalid-json')"
  environment_id="$(jq -r '.environmentId // ""' <<<"$output" 2>/dev/null || true)"
  remote_note "Remote Control check $attempt: status=$status timedOut=$timed_out."
  jq -e '
    .status == "connected" and
    .timedOut == false and
    (.environmentId | type == "string" and length > 0) and
    (.daemon.status | type == "string" and length > 0)
  ' <<<"$output" >/dev/null 2>&1 && [[ -n "$environment_id" ]]
}

wait_for_remote_control() {
  local phase="$1"
  local attempt
  for attempt in 1 2 3; do
    if remote_control_connected_once "$phase.$attempt"; then
      return 0
    fi
    if [[ "$attempt" != "3" && "$RETRY_SECONDS" != "0" ]]; then
      remote_note "Waiting ${RETRY_SECONDS}s before the next connection check."
      sleep "$RETRY_SECONDS"
    fi
  done
  return 1
}

repair_remote_control() {
  local context="$1"
  local bin
  bin="$CODEX_LINK/$MANAGED_RELATIVE_PATH"
  [[ -x "$bin" ]] || {
    remote_note "Managed Codex executable is missing at $bin."
    return 1
  }
  "$bin" login status >/dev/null 2>&1 || {
    remote_note "Codex login is missing; run scripts/codex-vm.sh pair from the Mac checkout"
    return 1
  }
  remote_note "Checking Remote Control for $context."
  if wait_for_remote_control "start"; then
    remote_note "Remote Control is connected."
    return 0
  fi
  remote_note "Supported start did not connect; invoking $RECOVERY_HELPER."
  if ! "$RECOVERY_HELPER"; then
    remote_note "The VM recovery helper returned failure; checking connection once more."
  fi
  if wait_for_remote_control "repair"; then
    remote_note "Remote Control recovered and is connected."
    return 0
  fi
  remote_note "Remote Control is not connected after bounded repair attempts."
  return 1
}

rollback_on_exit() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$status" != "0" && "$MOVED_OLD_CODEX" == "1" ]]; then
    remote_note "Rolling back the Codex-home migration."
    if [[ "$CREATED_LINK" == "1" && -L "$CODEX_LINK" ]]; then
      rm -- "$CODEX_LINK"
    fi
    if [[ ! -e "$CODEX_LINK" && ! -L "$CODEX_LINK" && ( -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ) ]]; then
      mv -- "$BACKUP_PATH" "$CODEX_LINK"
    fi
  fi
  if [[ "$status" != "0" && "$DAEMON_STOPPED" == "1" && -x "$CODEX_LINK/$MANAGED_RELATIVE_PATH" ]]; then
    remote_note "Attempting Remote Control recovery on the restored Codex home."
    repair_remote_control "the restored Codex home" ||
      printf 'Remote Dot Codex bootstrap rollback warning: the prior Remote Control connection did not recover\n' >&2
  fi
  exit "$status"
}

next_backup_path() {
  local base candidate suffix
  base="$HOME/.codex.backup.$(date +%Y%m%d-%H%M%S)"
  candidate="$base"
  suffix=0
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    suffix=$((suffix + 1))
    candidate="$base.$suffix"
  done
  printf '%s\n' "$candidate"
}

trap rollback_on_exit EXIT
trap 'exit 130' INT TERM

for command in git jq readlink sleep tar; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
[[ "$DOT_CODEX_DIR" == /* ]] || fail "remote clone path must be absolute"
[[ "$DOT_CODEX_DIR" != "$CODEX_LINK" ]] || fail "remote clone path must differ from ~/.codex"
[[ "$RECOVERY_HELPER" == /* && -x "$RECOVERY_HELPER" ]] || fail "VM recovery helper is unavailable or not executable at $RECOVERY_HELPER"
[[ "$RETRY_SECONDS" =~ ^[0-9]+$ ]] || fail "remote retry delay must be an integer"
((RETRY_SECONDS <= 30)) || fail "remote retry delay must be between 0 and 30"

if [[ -e "$DOT_CODEX_DIR" || -L "$DOT_CODEX_DIR" ]]; then
  remote_note "Inspecting existing clone at $DOT_CODEX_DIR."
  [[ -d "$DOT_CODEX_DIR" && ! -L "$DOT_CODEX_DIR" ]] || fail "clone target exists but is not a real directory: $DOT_CODEX_DIR"
  [[ "$(git -C "$DOT_CODEX_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] ||
    fail "clone target is not a Git worktree: $DOT_CODEX_DIR"
  CLONE_ROOT="$(git -C "$DOT_CODEX_DIR" rev-parse --show-toplevel)"
  [[ "$(readlink -f "$CLONE_ROOT")" == "$(readlink -f "$DOT_CODEX_DIR")" ]] ||
    fail "clone target is nested inside a different Git worktree: $DOT_CODEX_DIR"
  ACTUAL_ORIGIN="$(git -C "$DOT_CODEX_DIR" remote get-url origin 2>/dev/null)" ||
    fail "clone target has no origin remote"
  [[ "$ACTUAL_ORIGIN" == "$REPOSITORY_URL" ]] ||
    fail "clone origin is $ACTUAL_ORIGIN, expected $REPOSITORY_URL"
  [[ -z "$(git -C "$DOT_CODEX_DIR" status --porcelain --untracked-files=normal)" ]] ||
    fail "clone has local worktree or index changes: $DOT_CODEX_DIR"
  CURRENT_BRANCH="$(git -C "$DOT_CODEX_DIR" symbolic-ref --quiet --short HEAD)" ||
    fail "clone is detached"
  UPSTREAM="$(git -C "$DOT_CODEX_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" ||
    fail "branch $CURRENT_BRANCH has no upstream"
  [[ "$UPSTREAM" == origin/* ]] || fail "branch $CURRENT_BRANCH does not track origin"
  ORIGINAL_HEAD="$(git -C "$DOT_CODEX_DIR" rev-parse HEAD)"
  remote_note "Fetching origin before the default rebase."
  git -C "$DOT_CODEX_DIR" fetch --prune origin
  FORK_POINT="$(git -C "$DOT_CODEX_DIR" merge-base --fork-point "$UPSTREAM" "$ORIGINAL_HEAD" 2>/dev/null)" ||
    fail "could not determine a reflog-aware fork point for $CURRENT_BRANCH and $UPSTREAM"
  git -C "$DOT_CODEX_DIR" merge-base --is-ancestor "$FORK_POINT" "$ORIGINAL_HEAD" ||
    fail "reflog-aware fork point is not an ancestor of the original branch"
  remote_note "Rebasing VM-only commits after the reflog-aware fork point onto $UPSTREAM."
  if ! git -C "$DOT_CODEX_DIR" rebase --onto "$UPSTREAM" "$FORK_POINT" "$CURRENT_BRANCH"; then
    ABSOLUTE_GIT_DIR="$(git -C "$DOT_CODEX_DIR" rev-parse --absolute-git-dir)"
    if [[ -d "$ABSOLUTE_GIT_DIR/rebase-merge" || -d "$ABSOLUTE_GIT_DIR/rebase-apply" ]]; then
      remote_note "Rebase did not apply cleanly; aborting it."
      git -C "$DOT_CODEX_DIR" rebase --abort ||
        fail "rebase failed and automatic abort could not restore the original branch"
    fi
    [[ "$(git -C "$DOT_CODEX_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null)" == "$CURRENT_BRANCH" ]] ||
      fail "rebase failed and did not restore branch $CURRENT_BRANCH"
    [[ "$(git -C "$DOT_CODEX_DIR" rev-parse HEAD)" == "$ORIGINAL_HEAD" ]] ||
      fail "rebase failed and did not restore the original branch commit"
    [[ -z "$(git -C "$DOT_CODEX_DIR" status --porcelain --untracked-files=normal)" ]] ||
      fail "rebase failed and did not restore a clean worktree"
    fail "rebase conflicted; original branch restored"
  fi
  git -C "$DOT_CODEX_DIR" merge-base --is-ancestor "$UPSTREAM" HEAD ||
    fail "rebase completed without placing $UPSTREAM behind the local branch"
else
  remote_note "Clone is missing; cloning $REPOSITORY_URL."
  git clone -- "$REPOSITORY_URL" "$DOT_CODEX_DIR"
fi

if [[ -L "$CODEX_LINK" ]] &&
  [[ "$(readlink -f "$CODEX_LINK")" == "$(readlink -f "$DOT_CODEX_DIR")" ]]; then
  remote_note "Symlink already correct; no backup or migration needed."
  repair_remote_control "the existing dot-codex home" ||
    fail "Remote Control is not connected after bounded repair attempts"
  printf 'Remote Dot Codex clone and symlink are ready at %s.\n' "$DOT_CODEX_DIR"
  ls -ld "$CODEX_LINK"
  exit 0
fi

if [[ -x "$CODEX_LINK/$MANAGED_RELATIVE_PATH" ]]; then
  remote_note "Checking Codex login before changing the active home."
  "$CODEX_LINK/$MANAGED_RELATIVE_PATH" login status >/dev/null 2>&1 ||
    fail "Codex is not logged in; run scripts/codex-vm.sh pair from the Mac checkout"
  remote_note "Stopping the managed daemon before migration."
  "$CODEX_LINK/$MANAGED_RELATIVE_PATH" app-server daemon stop
  DAEMON_STOPPED=1
fi

if [[ -e "$CODEX_LINK" || -L "$CODEX_LINK" ]]; then
  BACKUP_PATH="$(next_backup_path)"
  remote_note "Moving the previous Codex home to $BACKUP_PATH."
  mv -- "$CODEX_LINK" "$BACKUP_PATH"
  MOVED_OLD_CODEX=1
  if [[ -d "$BACKUP_PATH" ]]; then
    remote_note "Migrating VM-local ignored state while preserving Git-owned files."
    (
      cd "$BACKUP_PATH"
      tar --exclude='.git' -cf - .
    ) | (
      cd "$DOT_CODEX_DIR"
      tar -xf -
    )
    git -C "$DOT_CODEX_DIR" restore --source=HEAD --staged --worktree -- .
  fi
fi

remote_note "Creating ~/.codex -> $DOT_CODEX_DIR."
ln -s -- "$DOT_CODEX_DIR" "$CODEX_LINK"
CREATED_LINK=1
[[ -L "$CODEX_LINK" ]] || fail "~/.codex was not created as a symlink"
[[ "$(readlink -f "$CODEX_LINK")" == "$(readlink -f "$DOT_CODEX_DIR")" ]] ||
  fail "~/.codex does not resolve to $DOT_CODEX_DIR"

repair_remote_control "the migrated dot-codex home" ||
  fail "Remote Control is not connected after bounded repair attempts"

printf 'Remote Dot Codex clone is ready at %s.\n' "$DOT_CODEX_DIR"
if [[ -n "$BACKUP_PATH" ]]; then
  printf 'Previous ~/.codex preserved at %s.\n' "$BACKUP_PATH"
fi
ls -ld "$CODEX_LINK"
REMOTE_SCRIPT

step "Close temporary SSH"
"$ROOT/scripts/ssh-close.sh"
SSH_OPENED=0
note "Temporary SSH is closed."

step "Verify Remote Control after SSH closure"
"$ROOT/scripts/remote-control-recover.sh" ||
  fail "final Remote Control verification failed; run scripts/codex-vm.sh setup after checking VM login and network access"
printf 'Remote Control verified connected.\n'

step "Complete"
printf 'Dot Codex bootstrap and repair completed successfully.\n'
printf '  Clone: %s\n' "${REMOTE_DIR:-\$HOME/projects/dot-codex}"
printf '  Symlink: \$HOME/.codex -> %s\n' "${REMOTE_DIR:-\$HOME/projects/dot-codex}"
printf '  SSH: closed\n'
printf '  Remote Control: connected\n'
__CODEX_VM_HELPER_END__ dot-codex-bootstrap.sh

__CODEX_VM_HELPER_BEGIN__ remote-control-recover.sh
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
HELPER_PATH="$ROOT/vm-scripts/ensure-codex-remote-control.sh"

fail() {
  printf 'Remote Control recovery failed: %s\n' "$1" >&2
  exit 1
}

for command in az python3 terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
[[ -f "$HELPER_PATH" && -r "$HELPER_PATH" ]] || fail "missing VM recovery helper: $HELPER_PATH"

CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
IFS=$'\t' read -r SUBSCRIPTION_ID RESOURCE_GROUP VM_NAME SSH_USERNAME <<<"$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os
import re

value = json.loads(os.environ["CONNECTION"])
fields = [value[key] for key in ("subscription_id", "resource_group_name", "vm_name", "ssh_username")]
patterns = [
    r"[0-9a-fA-F-]{36}",
    r"[A-Za-z0-9._()/-]{1,90}",
    r"[A-Za-z0-9-]{1,64}",
    r"[a-z_][a-z0-9_-]{0,31}",
]
if any(re.fullmatch(pattern, field) is None for pattern, field in zip(patterns, fields)):
    raise SystemExit("Terraform connection output contains an unsafe recovery identifier")
print("\t".join(fields))
PY
)"

[[ "$(az account show --query id --output tsv)" == "$SUBSCRIPTION_ID" ]] || fail "Azure CLI is using a different subscription"

REMOTE_SCRIPT="$(HELPER_PATH="$HELPER_PATH" SSH_USERNAME="$SSH_USERNAME" python3 - <<'PY'
import base64
import hashlib
import os
import pathlib
import shlex

helper = pathlib.Path(os.environ["HELPER_PATH"]).read_bytes()
encoded_helper = base64.b64encode(helper).decode("ascii")
expected_sha = hashlib.sha256(helper).hexdigest()
username = os.environ["SSH_USERNAME"]
target = "/usr/local/sbin/ensure-codex-remote-control"
home = f"/home/{username}"
quote = shlex.quote

print(
    f"""#!/bin/sh
set -eu
target={quote(target)}
expected_sha={quote(expected_sha)}
tmp="$(mktemp)"
trap 'rm -f "$tmp"' 0 HUP INT TERM
printf '%s' {quote(encoded_helper)} | base64 --decode >"$tmp"
actual_sha="$(sha256sum "$tmp" | awk '{{print $1}}')"
if [ "$actual_sha" != "$expected_sha" ]; then
  printf 'VM recovery helper payload checksum mismatch\\n' >&2
  exit 1
fi
if ! cmp -s "$tmp" "$target"; then
  install -o root -g root -m 0755 "$tmp" "$target"
fi
if ! cmp -s "$tmp" "$target"; then
  printf 'VM recovery helper reconciliation failed\\n' >&2
  exit 1
fi
runuser -u {quote(username)} -- env HOME={quote(home)} CODEX_HOME={quote(f"{home}/.codex")} "$target"
"""
)
PY
)"
az vm run-command invoke \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$REMOTE_SCRIPT" \
  --only-show-errors >/dev/null

printf 'Remote Control recovery completed through Azure Run Command; SSH remained closed.\n'
__CODEX_VM_HELPER_END__ remote-control-recover.sh

__CODEX_VM_HELPER_BEGIN__ ssh-open.sh
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
STATE_FILE="${CODEX_SSH_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-on-vm/ssh-access.json}"
LOCK_DIR="${STATE_FILE}.lock"
RULE_NAME=""
LOCK_HELD=0
RULE_CREATED=0
SUCCESS=0
RESOURCE_GROUP=""
NSG_NAME=""

fail() {
  printf 'SSH open failed: %s\n' "$1" >&2
  exit 1
}

cleanup_on_exit() {
  local status=$?
  set +e
  if [[ "$SUCCESS" != "1" && "$RULE_CREATED" == "1" ]]; then
    az network nsg rule delete --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null 2>&1
    if ! az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null 2>&1; then
      rm -f "$STATE_FILE"
    else
      printf 'SSH open cleanup warning: the temporary rule may remain; run scripts/codex-vm.sh ssh-close\n' >&2
    fi
  fi
  if [[ "$LOCK_HELD" == "1" ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  return "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

for command in az curl python3 terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
install -d -m 0700 "$(dirname "$STATE_FILE")"
mkdir "$LOCK_DIR" 2>/dev/null || fail "another temporary SSH operation is running"
LOCK_HELD=1
[[ ! -e "$STATE_FILE" ]] || fail "temporary SSH state already exists; run scripts/codex-vm.sh ssh-close"

CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
IFS=$'\t' read -r SUBSCRIPTION_ID RESOURCE_GROUP NSG_NAME RULE_NAME SSH_ALIAS <<<"$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["CONNECTION"])
print("\t".join(value[key] for key in ("subscription_id", "resource_group_name", "network_security_group_name", "temporary_ssh_rule_name", "ssh_alias")))
PY
)"
[[ "$(az account show --query id --output tsv)" == "$SUBSCRIPTION_ID" ]] || fail "Azure CLI is using a different subscription"

PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org)"
PUBLIC_IP_CIDR="$(PUBLIC_IP="$PUBLIC_IP" python3 - <<'PY'
import ipaddress
import os

address = ipaddress.IPv4Address(os.environ["PUBLIC_IP"])
if not address.is_global:
    raise SystemExit("current public IPv4 address is not globally routable")
print(f"{address}/32")
PY
)"
if az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null 2>&1; then
  fail "the temporary SSH rule already exists; run scripts/codex-vm.sh ssh-close"
fi

STATE_FILE="$STATE_FILE" SUBSCRIPTION_ID="$SUBSCRIPTION_ID" RESOURCE_GROUP="$RESOURCE_GROUP" NSG_NAME="$NSG_NAME" RULE_NAME="$RULE_NAME" PUBLIC_IP_CIDR="$PUBLIC_IP_CIDR" SSH_ALIAS="$SSH_ALIAS" python3 - <<'PY'
import json
import os
import pathlib

path = pathlib.Path(os.environ["STATE_FILE"])
value = {key.lower(): os.environ[key] for key in ("SUBSCRIPTION_ID", "RESOURCE_GROUP", "NSG_NAME", "RULE_NAME", "PUBLIC_IP_CIDR", "SSH_ALIAS")}
temporary = path.with_suffix(path.suffix + ".tmp")
temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.chmod(0o600)
temporary.replace(path)
PY

az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "$RULE_NAME" \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes "$PUBLIC_IP_CIDR" \
  --source-port-ranges '*' \
  --destination-address-prefixes '*' \
  --destination-port-ranges 22 \
  --only-show-errors >/dev/null
RULE_CREATED=1

SOURCE="$(az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --query sourceAddressPrefix --output tsv --only-show-errors)"
PORT="$(az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --query destinationPortRange --output tsv --only-show-errors)"
ACCESS="$(az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --query access --output tsv --only-show-errors)"
[[ "$SOURCE" == "$PUBLIC_IP_CIDR" && "$PORT" == "22" && "$ACCESS" == "Allow" ]] || fail "temporary rule read-back did not match the requested /32 TCP/22 access"

SUCCESS=1
printf 'Temporary SSH opened for %s. Connect with: ssh %s\n' "$PUBLIC_IP_CIDR" "$SSH_ALIAS"
printf 'Close it when finished with: scripts/codex-vm.sh ssh-close\n'
__CODEX_VM_HELPER_END__ ssh-open.sh

__CODEX_VM_HELPER_BEGIN__ ssh-close.sh
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
STATE_FILE="${CODEX_SSH_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-on-vm/ssh-access.json}"
LOCK_DIR="${STATE_FILE}.lock"
RULE_NAME=""
LOCK_HELD=0

fail() {
  printf 'SSH close failed: %s\n' "$1" >&2
  exit 1
}

cleanup_on_exit() {
  local status=$?
  if [[ "$LOCK_HELD" == "1" ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  return "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

for command in az python3 terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
install -d -m 0700 "$(dirname "$STATE_FILE")"
mkdir "$LOCK_DIR" 2>/dev/null || fail "another temporary SSH operation is running"
LOCK_HELD=1

if [[ -f "$STATE_FILE" ]]; then
  IFS=$'\t' read -r SUBSCRIPTION_ID RESOURCE_GROUP NSG_NAME RULE_NAME <<<"$(STATE_FILE="$STATE_FILE" python3 - <<'PY'
import json
import os

with open(os.environ["STATE_FILE"], encoding="utf-8") as handle:
    value = json.load(handle)
print("\t".join(value[key] for key in ("subscription_id", "resource_group", "nsg_name", "rule_name")))
PY
)"
else
  CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
  IFS=$'\t' read -r SUBSCRIPTION_ID RESOURCE_GROUP NSG_NAME RULE_NAME <<<"$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["CONNECTION"])
print("\t".join(value[key] for key in ("subscription_id", "resource_group_name", "network_security_group_name", "temporary_ssh_rule_name")))
PY
)"
fi

[[ "$(az account show --query id --output tsv)" == "$SUBSCRIPTION_ID" ]] || fail "Azure CLI is using a different subscription; recovery state was retained"

if az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null 2>&1; then
  az network nsg rule delete --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null
fi
for _attempt in {1..30}; do
  if ! az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null 2>&1; then
    rm -f "$STATE_FILE"
    printf 'Temporary SSH rule is closed.\n'
    exit 0
  fi
  sleep 2
done
fail "temporary SSH rule is still present; recovery state was retained"
__CODEX_VM_HELPER_END__ ssh-close.sh

__CODEX_VM_HELPER_BEGIN__ workspace-open.sh
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
SUCCESS=0
SSH_OPENED=0
MOUNT_PATH=""

fail() {
  printf 'Workspace open failed: %s\n' "$1" >&2
  exit 1
}

cleanup_on_exit() {
  local status=$?
  set +e
  if [[ "$SUCCESS" != "1" ]]; then
    if [[ -n "$MOUNT_PATH" ]] && mount | grep -F " on $MOUNT_PATH " >/dev/null 2>&1; then
      diskutil unmount "$MOUNT_PATH" >/dev/null 2>&1 || true
    fi
    if [[ "$SSH_OPENED" == "1" ]]; then
      "$ROOT/scripts/ssh-close.sh" >/dev/null 2>&1 || true
    fi
  fi
  return "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

[[ "$#" -le 1 ]] || fail "expected zero or one remote path argument"
REMOTE_PATH_OVERRIDE="${1:-}"
if [[ -n "$REMOTE_PATH_OVERRIDE" ]]; then
  [[ "$REMOTE_PATH_OVERRIDE" == /* ]] || fail "remote path must be absolute"
  [[ "$REMOTE_PATH_OVERRIDE" != *$'\n'* && "$REMOTE_PATH_OVERRIDE" != *$'\r'* && "$REMOTE_PATH_OVERRIDE" != *$'\t'* ]] || fail "remote path must not contain control characters"
fi

[[ "$(uname -s)" == "Darwin" ]] || fail "this helper is for macOS"
for command in diskutil find mount python3 sshfs terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done

CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
IFS=$'\t' read -r SSH_ALIAS DEFAULT_REMOTE_PATH DEFAULT_MOUNT <<<"$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["CONNECTION"])
print("\t".join(value[key] for key in ("ssh_alias", "workspace_mount_path", "local_mount_path")))
PY
)"
REMOTE_PATH="${REMOTE_PATH_OVERRIDE:-$DEFAULT_REMOTE_PATH}"
MOUNT_PATH="${CODEX_WORKSPACE_LOCAL_MOUNT_PATH:-$DEFAULT_MOUNT}"
mkdir -p "$MOUNT_PATH"
if mount | grep -F " on $MOUNT_PATH " >/dev/null 2>&1; then
  fail "$MOUNT_PATH is already mounted"
fi
[[ -z "$(find "$MOUNT_PATH" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "$MOUNT_PATH must be empty"

"$ROOT/scripts/ssh-open.sh"
SSH_OPENED=1
sshfs "$SSH_ALIAS:$REMOTE_PATH" "$MOUNT_PATH" \
  -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,volname=codex-on-vm
mount | grep -F " on $MOUNT_PATH " >/dev/null || fail "SSHFS mount read-back failed"

SUCCESS=1
printf 'Workspace mounted at %s. Run scripts/codex-vm.sh workspace-close when finished.\n' "$MOUNT_PATH"
__CODEX_VM_HELPER_END__ workspace-open.sh

__CODEX_VM_HELPER_BEGIN__ workspace-close.sh
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"

fail() {
  printf 'Workspace close failed: %s\n' "$1" >&2
  exit 1
}

for command in diskutil mount python3 terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done

CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
DEFAULT_MOUNT="$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["CONNECTION"])["local_mount_path"])
PY
)"
MOUNT_PATH="${CODEX_WORKSPACE_LOCAL_MOUNT_PATH:-$DEFAULT_MOUNT}"

if mount | grep -F " on $MOUNT_PATH " >/dev/null 2>&1; then
  diskutil unmount "$MOUNT_PATH" >/dev/null || fail "could not unmount $MOUNT_PATH; SSH access remains open for recovery"
fi
if mount | grep -F " on $MOUNT_PATH " >/dev/null 2>&1; then
  fail "$MOUNT_PATH is still mounted; SSH access remains open for recovery"
fi
"$ROOT/scripts/ssh-close.sh"
printf 'Workspace unmounted and temporary SSH closed.\n'
__CODEX_VM_HELPER_END__ workspace-close.sh


__CODEX_VM_HELPER_BEGIN__ ensure-codex-remote-control.sh
#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_BIN="$CODEX_HOME/packages/standalone/current/codex"
DAEMON_DIR="$CODEX_HOME/app-server-daemon"
APP_PID_FILE="$DAEMON_DIR/app-server.pid"
UPDATER_PID_FILE="$DAEMON_DIR/app-server-updater.pid"
PS_BIN="${CODEX_RECOVERY_PS:-/usr/bin/ps}"
KILL_BIN="${CODEX_RECOVERY_KILL:-/bin/kill}"
SLEEP_BIN="${CODEX_RECOVERY_SLEEP:-/usr/bin/sleep}"
CMP_BIN="${CODEX_RECOVERY_CMP:-/usr/bin/cmp}"
PROC_ROOT="${CODEX_RECOVERY_PROC_ROOT:-/proc}"
PROCESS_USER="$(id -un)"

fail() {
  printf 'Codex Remote Control recovery failed: %s\n' "$1" >&2
  exit 1
}

daemon_ready() {
  local output managed_codex_path
  output="$("$CODEX_BIN" app-server daemon version)" || return 1
  managed_codex_path="$(jq -er '
    select(
      .status == "running" and
      (.appServerVersion | type == "string" and length > 0) and
      (.managedCodexPath | type == "string" and length > 0)
    )
    | .managedCodexPath
  ' <<<"$output")" || return 1
  [[ "$managed_codex_path" -ef "$CODEX_BIN" ]]
}

try_supported_recovery() {
  if "$CODEX_BIN" remote-control start --json && daemon_ready; then
    return 0
  fi
  if "$CODEX_BIN" app-server daemon restart && \
    "$CODEX_BIN" remote-control start --json && daemon_ready; then
    return 0
  fi
  return 1
}

record_value() {
  local path="$1"
  local field="$2"
  [[ -f "$path" ]] || return 1
  jq -er --arg field "$field" '.[$field]' "$path"
}

process_value() {
  local pid="$1"
  local field="$2"
  "$PS_BIN" -p "$pid" -o "$field" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

same_executable_content() {
  local candidate="$1"
  [[ -x "$candidate" && -x "$CODEX_BIN" ]] || return 1
  [[ "$candidate" -ef "$CODEX_BIN" ]] || "$CMP_BIN" -s "$candidate" "$CODEX_BIN"
}

verified_stale_processes() {
  local updater_args updater_executable
  UPDATER_PID="$(record_value "$UPDATER_PID_FILE" pid)" || return 1
  UPDATER_STARTED="$(record_value "$UPDATER_PID_FILE" processStartTime)" || return 1
  APP_PID="$(record_value "$APP_PID_FILE" pid)" || return 1
  APP_STARTED="$(record_value "$APP_PID_FILE" processStartTime)" || return 1
  [[ "$UPDATER_PID" =~ ^[0-9]+$ && "$UPDATER_PID" -gt 1 ]] || return 1
  [[ "$APP_PID" =~ ^[0-9]+$ && "$APP_PID" -gt 1 ]] || return 1
  [[ "$(process_value "$UPDATER_PID" user=)" == "$PROCESS_USER" ]] || return 1
  [[ "$(process_value "$UPDATER_PID" lstart=)" == "$UPDATER_STARTED" ]] || return 1
  updater_args="$(process_value "$UPDATER_PID" args=)" || return 1
  updater_executable="${updater_args% app-server daemon pid-update-loop}"
  [[ -n "$updater_executable" && "$updater_executable" != "$updater_args" ]] || return 1
  same_executable_content "$updater_executable" || return 1
  same_executable_content "$PROC_ROOT/$UPDATER_PID/exe" || return 1
  [[ "$(process_value "$APP_PID" user=)" == "$PROCESS_USER" ]] || return 1
  [[ "$(process_value "$APP_PID" lstart=)" == "$APP_STARTED" ]] || return 1
  [[ "$(process_value "$APP_PID" stat=)" == Z* ]] || return 1
  [[ "$(process_value "$APP_PID" ppid=)" == "$UPDATER_PID" ]] || return 1
}

terminate_verified_stale_parent() {
  verified_stale_processes || return 1
  "$KILL_BIN" -TERM "$UPDATER_PID"
  for _attempt in {1..10}; do
    if ! process_value "$UPDATER_PID" user= >/dev/null 2>&1 && \
      ! process_value "$APP_PID" user= >/dev/null 2>&1; then
      return 0
    fi
    "$SLEEP_BIN" 1
  done
  return 1
}

command -v jq >/dev/null || fail "jq is unavailable"
[[ -x "$CMP_BIN" ]] || fail "cmp is unavailable at $CMP_BIN"
[[ -x "$CODEX_BIN" ]] || fail "managed Codex install is unavailable at $CODEX_BIN"

if try_supported_recovery; then
  printf 'Codex Remote Control is ready.\n'
  exit 0
fi

terminate_verified_stale_parent || fail "supported lifecycle recovery failed and the stale process state was not safe to terminate"
try_supported_recovery || fail "managed daemon did not recover after terminating the verified stale updater"
printf 'Codex Remote Control recovered from a verified stale updater.\n'
__CODEX_VM_HELPER_END__ ensure-codex-remote-control.sh

__CODEX_VM_HELPER_BEGIN__ ensure-ssh-keys.sh
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
__CODEX_VM_HELPER_END__ ensure-ssh-keys.sh

__CODEX_VM_HELPER_BEGIN__ fetch-verified-artifact.sh
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
__CODEX_VM_HELPER_END__ fetch-verified-artifact.sh

__CODEX_VM_HELPER_BEGIN__ install-verified-codex.sh
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
__CODEX_VM_HELPER_END__ install-verified-codex.sh

__CODEX_VM_HELPER_BEGIN__ prepare-codex-vm.sh
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  printf 'usage: %s <admin-user> <projects-mount> <disk-lun> <codex-version> <package-url> <package-sha256>\n' "$0" >&2
  exit 64
fi

ADMIN_USER="$1"
MOUNT_PATH="$2"
DISK_LUN="$3"
CODEX_VERSION="$4"
CODEX_PACKAGE_URL="$5"
CODEX_PACKAGE_SHA256="$6"
VM_ROOT="${CODEX_VM_ROOT:-}"
TEST_MODE="${CODEX_VM_TEST_MODE:-0}"
DATA_DISK="${CODEX_VM_DATA_DISK:-/dev/disk/azure/data/by-lun/$DISK_LUN}"

fail() {
  printf 'Codex VM preparation failed: %s\n' "$1" >&2
  exit 1
}

root_path() {
  printf '%s%s\n' "$VM_ROOT" "$1"
}

device_exists() {
  if [[ "$TEST_MODE" == "1" ]]; then
    [[ -e "$1" ]]
  else
    [[ -b "$1" ]]
  fi
}

install_owned_dir() {
  local mode="$1"
  local path="$2"
  if [[ "$TEST_MODE" == "1" ]]; then
    install -d -m "$mode" "$path"
  else
    install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m "$mode" "$path"
  fi
}

write_if_changed() {
  local mode="$1"
  local target="$2"
  local temporary
  install -d -m 0755 "$(dirname "$target")"
  temporary="$(mktemp)"
  cat >"$temporary"
  if [[ ! -f "$target" ]] || ! cmp -s "$temporary" "$target"; then
    if [[ "$TEST_MODE" == "1" ]]; then
      install -m "$mode" "$temporary" "$target"
    else
      install -o root -g root -m "$mode" "$temporary" "$target"
    fi
  fi
  rm -f "$temporary"
}

install_packages() {
  local attempt
  for attempt in $(seq 1 12); do
    if DEBIAN_FRONTEND=noninteractive apt-get update &&
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        apparmor-profiles \
        apparmor-utils \
        azure-vm-utils \
        bubblewrap \
        ca-certificates \
        curl \
        e2fsprogs \
        fail2ban \
        git \
        jq \
        parted \
        unattended-upgrades; then
      return
    fi
    sleep 10
  done
  fail "Ubuntu package installation did not converge"
}

configure_apparmor() {
  local source target
  source="$(root_path /usr/share/apparmor/extra-profiles/bwrap-userns-restrict)"
  target="$(root_path /etc/apparmor.d/bwrap-userns-restrict)"
  command -v bwrap >/dev/null || fail "bubblewrap is unavailable after package installation"
  command -v apparmor_parser >/dev/null || fail "AppArmor parser is unavailable"
  [[ -f "$source" ]] || fail "Ubuntu bubblewrap AppArmor profile is unavailable"
  install -d -m 0755 "$(dirname "$target")"
  if [[ "$TEST_MODE" == "1" ]]; then
    install -m 0644 "$source" "$target"
  else
    install -o root -g root -m 0644 "$source" "$target"
  fi
  apparmor_parser -r "$target"
}

prepare_workspace_disk() {
  local partition filesystem_device filesystem_type filesystem_uuid created_partition attempt
  for attempt in $(seq 1 120); do
    device_exists "$DATA_DISK" && break
    sleep 5
  done
  device_exists "$DATA_DISK" || fail "managed data disk is unavailable at $DATA_DISK"

  partition="$(lsblk -nrpo NAME,TYPE "$DATA_DISK" | awk '$2 == "part" { print $1; exit }')"
  created_partition=0
  if [[ -n "$partition" ]]; then
    filesystem_device="$partition"
  elif [[ -n "$(blkid -s TYPE -o value "$DATA_DISK" 2>/dev/null || true)" ]]; then
    filesystem_device="$DATA_DISK"
  else
    [[ -z "$(wipefs --no-act "$DATA_DISK" 2>/dev/null)" ]] || fail "unformatted disk contains unexpected signatures"
    parted "$DATA_DISK" --script mklabel gpt mkpart primary ext4 0% 100%
    partprobe "$DATA_DISK"
    udevadm settle
    partition="$(lsblk -nrpo NAME,TYPE "$DATA_DISK" | awk '$2 == "part" { print $1; exit }')"
    device_exists "$partition" || fail "partition creation did not produce a device"
    filesystem_device="$partition"
    created_partition=1
  fi

  filesystem_type="$(blkid -s TYPE -o value "$filesystem_device" 2>/dev/null || true)"
  if [[ -z "$filesystem_type" ]]; then
    [[ "$created_partition" == "1" ]] || fail "refusing to format a pre-existing untyped device"
    mkfs.ext4 -L codex-workspace "$filesystem_device"
    filesystem_type=ext4
  fi
  [[ "$filesystem_type" == "ext4" ]] || fail "workspace filesystem must be ext4"
  filesystem_uuid="$(blkid -s UUID -o value "$filesystem_device")"
  [[ -n "$filesystem_uuid" ]] || fail "workspace filesystem has no UUID"

  MOUNT_PHYSICAL="$(root_path "$MOUNT_PATH")"
  FSTAB_PATH="$(root_path /etc/fstab)"
  install_owned_dir 0770 "$MOUNT_PHYSICAL"
  install -d -m 0755 "$(dirname "$FSTAB_PATH")"
  touch "$FSTAB_PATH"
  sed -i.bak "\\|[[:space:]]$MOUNT_PATH[[:space:]]|d" "$FSTAB_PATH"
  rm -f "$FSTAB_PATH.bak"
  printf 'UUID=%s %s ext4 defaults,nofail,x-systemd.device-timeout=2min 0 2\n' \
    "$filesystem_uuid" "$MOUNT_PATH" >>"$FSTAB_PATH"
  mountpoint -q "$MOUNT_PHYSICAL" || mount "$MOUNT_PHYSICAL"
  [[ "$(findmnt -n -o FSTYPE "$MOUNT_PHYSICAL")" == "ext4" ]] || fail "workspace mount read-back failed"
  if [[ "$TEST_MODE" != "1" ]]; then
    chown "$ADMIN_USER:$ADMIN_USER" "$MOUNT_PHYSICAL"
  fi
  chmod 0770 "$MOUNT_PHYSICAL"
}

configure_runtime_files() {
  local admin_home_logical
  admin_home_logical="/home/$ADMIN_USER"
  write_if_changed 0644 "$(root_path /etc/systemd/system/codex-remote-control-bootstrap.service)" <<EOF
[Unit]
Description=Bootstrap the managed Codex Remote Control daemon after boot
Wants=network-online.target
After=network-online.target
RequiresMountsFor=$MOUNT_PATH
ConditionPathIsExecutable=$admin_home_logical/.codex/packages/standalone/current/codex

[Service]
Type=oneshot
User=$ADMIN_USER
Group=$ADMIN_USER
Environment=HOME=$admin_home_logical
Environment=CODEX_HOME=$admin_home_logical/.codex
ExecStart=$admin_home_logical/.codex/packages/standalone/current/codex app-server daemon bootstrap --remote-control
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

  write_if_changed 0644 "$(root_path /etc/systemd/system/codex-remote-control-health.service)" <<EOF
[Unit]
Description=Ensure the managed Codex Remote Control daemon is ready
Wants=network-online.target
After=network-online.target codex-remote-control-bootstrap.service
RequiresMountsFor=$MOUNT_PATH
ConditionPathIsExecutable=$admin_home_logical/.codex/packages/standalone/current/codex

[Service]
Type=oneshot
User=$ADMIN_USER
Group=$ADMIN_USER
Environment=HOME=$admin_home_logical
Environment=CODEX_HOME=$admin_home_logical/.codex
ExecStart=/usr/local/sbin/ensure-codex-remote-control
TimeoutStartSec=240
EOF

  write_if_changed 0644 "$(root_path /etc/systemd/system/codex-remote-control-health.timer)" <<'EOF'
[Unit]
Description=Check the managed Codex Remote Control daemon every minute

[Timer]
OnBootSec=2min
OnUnitInactiveSec=1min
Persistent=true
RandomizedDelaySec=10s
Unit=codex-remote-control-health.service

[Install]
WantedBy=timers.target
EOF

  write_if_changed 0644 "$(root_path /etc/ssh/sshd_config.d/60-codex-hardening.conf)" <<EOF
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
AllowUsers $ADMIN_USER
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:60
X11Forwarding no
GatewayPorts no
PermitTunnel no
AllowTcpForwarding local
EOF

  write_if_changed 0644 "$(root_path /etc/fail2ban/jail.d/sshd.local)" <<'EOF'
[sshd]
enabled = true
backend = systemd
port = 22
maxretry = 5
findtime = 10m
bantime = 1h
EOF
}

run_as_admin() {
  if [[ "$TEST_MODE" == "1" ]]; then
    "$@"
  else
    runuser -u "$ADMIN_USER" -- "$@"
  fi
}

install_codex() {
  local home_helper installer fetcher managed_codex
  home_helper="$(root_path /usr/local/sbin/prepare-persistent-codex-home)"
  installer="$(root_path /usr/local/sbin/install-verified-codex)"
  fetcher="$(root_path /usr/local/sbin/fetch-verified-artifact)"
  ADMIN_HOME_PHYSICAL="$(root_path "/home/$ADMIN_USER")"
  install_owned_dir 0700 "$ADMIN_HOME_PHYSICAL"
  ADMIN_CODEX_HOME="$(CODEX_VM_TEST_MODE="$TEST_MODE" "$home_helper" "$ADMIN_USER" "$ADMIN_HOME_PHYSICAL" "$MOUNT_PHYSICAL")"
  ADMIN_BIN_DIR="$MOUNT_PHYSICAL/.local/bin"
  install_owned_dir 0755 "$MOUNT_PHYSICAL/.local"
  install_owned_dir 0755 "$ADMIN_BIN_DIR"

  run_as_admin env HOME="$ADMIN_HOME_PHYSICAL" CODEX_HOME="$ADMIN_CODEX_HOME" \
    "$installer" "$CODEX_PACKAGE_URL" "$CODEX_PACKAGE_SHA256" "$CODEX_VERSION" \
    "$ADMIN_CODEX_HOME" "$ADMIN_BIN_DIR" "$fetcher"
  managed_codex="$ADMIN_CODEX_HOME/packages/standalone/current/codex"
  [[ -x "$managed_codex" ]] || fail "managed Codex executable is missing"
  [[ "$(run_as_admin "$managed_codex" --version | awk '{print $NF}')" == "$CODEX_VERSION" ]] ||
    fail "managed Codex version read-back failed"

  install -d -m 0755 "$(root_path /usr/local/bin)"
  ln -sfn "$ADMIN_BIN_DIR/codex" "$(root_path /usr/local/bin/codex)"
  [[ "$(run_as_admin "$(root_path /usr/local/bin/codex)" --version | awk '{print $NF}')" == "$CODEX_VERSION" ]] ||
    fail "published Codex version read-back failed"

  if ! run_as_admin env HOME="$ADMIN_HOME_PHYSICAL" CODEX_HOME="$ADMIN_CODEX_HOME" \
    "$managed_codex" app-server daemon bootstrap --remote-control; then
    run_as_admin env HOME="$ADMIN_HOME_PHYSICAL" CODEX_HOME="$ADMIN_CODEX_HOME" \
      "$managed_codex" app-server daemon bootstrap
  fi
}

finish_preparation() {
  local marker host_key_file host_key
  systemctl daemon-reload
  systemctl enable codex-remote-control-bootstrap.service codex-remote-control-health.timer
  systemctl enable --now fail2ban unattended-upgrades
  systemctl start codex-remote-control-health.timer
  install -d -m 0755 "$(root_path /run/sshd)"
  sshd -t
  if systemctl is-active --quiet ssh; then
    systemctl reload ssh
  elif systemctl is-active --quiet ssh.socket; then
    :
  else
    systemctl enable --now ssh
  fi

  marker="$(root_path /var/lib/codex-on-vm/prepared)"
  install -d -m 0755 "$(dirname "$marker")"
  printf 'codex_version=%s\nworkspace_mount=%s\n' "$CODEX_VERSION" "$MOUNT_PATH" >"$marker"

  host_key_file="$(root_path /etc/ssh/ssh_host_ed25519_key.pub)"
  [[ -f "$host_key_file" ]] || ssh-keygen -A
  host_key="$(awk 'NF >= 2 && $1 == "ssh-ed25519" { print $1 " " $2; found = 1; exit } END { if (!found) exit 1 }' "$host_key_file")"
  printf 'CODEX_ON_VM_PREPARED=1\n'
  printf 'SSH_HOST_PUBLIC_KEY=%s\n' "$host_key"
}

[[ -n "$ADMIN_USER" && "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail "admin user is invalid"
[[ "$MOUNT_PATH" == /* ]] || fail "projects mount must be absolute"
[[ "$DISK_LUN" =~ ^[0-9]+$ ]] || fail "disk LUN must be a non-negative integer"
[[ "$CODEX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Codex version must use x.y.z format"
[[ "$CODEX_PACKAGE_URL" == https://* ]] || fail "Codex package URL must use HTTPS"
[[ "$CODEX_PACKAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "Codex package digest is invalid"
[[ -z "$VM_ROOT" || "$TEST_MODE" == "1" ]] || fail "CODEX_VM_ROOT is available only in test mode"

install_packages
configure_apparmor
prepare_workspace_disk
configure_runtime_files
install_codex
finish_preparation
__CODEX_VM_HELPER_END__ prepare-codex-vm.sh

__CODEX_VM_HELPER_BEGIN__ prepare-persistent-codex-home.sh
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  printf 'usage: %s <admin-user> <admin-home> <projects-mount>\n' "$0" >&2
  exit 64
fi

ADMIN_USER="$1"
ADMIN_HOME="$2"
MOUNT_PATH="$3"
CODEX_LINK="$ADMIN_HOME/.codex"
PERSISTENT_CODEX_HOME="$MOUNT_PATH/.codex"
DOT_CODEX_HOME="$MOUNT_PATH/dot-codex"

fail() {
  printf 'persistent Codex home preparation failed: %s\n' "$1" >&2
  exit 1
}

[[ -n "$ADMIN_USER" ]] || fail "admin user is empty"
[[ "$ADMIN_HOME" == /* && -d "$ADMIN_HOME" ]] || fail "admin home is unavailable: $ADMIN_HOME"
[[ "$MOUNT_PATH" == /* && -d "$MOUNT_PATH" ]] || fail "projects mount is unavailable: $MOUNT_PATH"
TEST_MODE="${CODEX_VM_TEST_MODE:-0}"
if [[ "$TEST_MODE" == "1" ]]; then
  ADMIN_GROUP="$(id -gn)"
else
  ADMIN_GROUP="$(id -gn "$ADMIN_USER")" || fail "admin user is unavailable: $ADMIN_USER"
fi

if [[ -d "$DOT_CODEX_HOME" && ! -L "$DOT_CODEX_HOME" && -d "$DOT_CODEX_HOME/.git" ]]; then
  ADMIN_CODEX_HOME="$DOT_CODEX_HOME"
else
  ADMIN_CODEX_HOME="$PERSISTENT_CODEX_HOME"
  if [[ -e "$ADMIN_CODEX_HOME" || -L "$ADMIN_CODEX_HOME" ]]; then
    [[ -d "$ADMIN_CODEX_HOME" && ! -L "$ADMIN_CODEX_HOME" ]] ||
      fail "persistent Codex home is not a real directory: $ADMIN_CODEX_HOME"
  fi
fi

if [[ -L "$CODEX_LINK" ]]; then
  EXISTING_TARGET="$(readlink -f "$CODEX_LINK")" ||
    fail "existing Codex link has no resolvable target: $CODEX_LINK"
  SELECTED_TARGET="$(readlink -f "$ADMIN_CODEX_HOME")" ||
    fail "selected Codex home is unavailable: $ADMIN_CODEX_HOME"
  [[ "$EXISTING_TARGET" == "$SELECTED_TARGET" ]] ||
    fail "existing Codex link resolves to $EXISTING_TARGET, expected $SELECTED_TARGET"
elif [[ -e "$CODEX_LINK" ]]; then
  fail "refusing to overwrite the real Codex home at $CODEX_LINK"
fi

if [[ "$TEST_MODE" == "1" ]]; then
  install -d -m 0700 "$ADMIN_CODEX_HOME"
else
  install -d -o "$ADMIN_USER" -g "$ADMIN_GROUP" -m 0700 "$ADMIN_CODEX_HOME"
fi
if [[ ! -L "$CODEX_LINK" ]]; then
  ln -s -- "$ADMIN_CODEX_HOME" "$CODEX_LINK"
  if [[ "$TEST_MODE" != "1" ]]; then
    chown -h "$ADMIN_USER:$ADMIN_GROUP" "$CODEX_LINK"
  fi
fi

printf '%s\n' "$ADMIN_CODEX_HOME"
__CODEX_VM_HELPER_END__ prepare-persistent-codex-home.sh
