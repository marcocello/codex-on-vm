#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
export AZURE_CORE_COLLECT_TELEMETRY=no

fail() {
  printf 'Live systemd scenario failed: %s\n' "$1" >&2
  exit 1
}

command -v az >/dev/null || fail "Azure CLI is unavailable"
command -v jq >/dev/null || fail "jq is unavailable"
command -v terraform >/dev/null || fail "Terraform is unavailable"

OUTPUTS="$(terraform -chdir="$TF_DIR" output -json)"
SUBSCRIPTION_ID="$(jq -er '.connection.value.subscription_id' <<<"$OUTPUTS")"
RESOURCE_GROUP="$(jq -er '.connection.value.resource_group_name' <<<"$OUTPUTS")"
VM_NAME="$(jq -er '.connection.value.vm_name' <<<"$OUTPUTS")"
ADMIN_USER="$(jq -er '.connection.value.ssh_username' <<<"$OUTPUTS")"
[[ "$SUBSCRIPTION_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "Terraform subscription ID is invalid"
[[ "$RESOURCE_GROUP" =~ ^[A-Za-z0-9._()/-]+$ ]] || fail "Terraform resource group is invalid"
[[ "$VM_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Terraform VM name is invalid"
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail "Terraform SSH username is invalid"

ACTIVE_SUBSCRIPTION="$(az account show --query id --output tsv)"
[[ "$ACTIVE_SUBSCRIPTION" == "$SUBSCRIPTION_ID" ]] ||
  fail "active Azure subscription does not match Terraform output"

REMOTE_BODY="$(cat <<EOF
set -euo pipefail
trap 'printf "LIVE_SYSTEMD_PROOF_ERROR line=%s status=%s\\n" "\$LINENO" "\$?" >&2' ERR
admin_user='$ADMIN_USER'
admin_home="/home/\$admin_user"
codex_home="\$admin_home/.codex"
codex_bin="\$codex_home/packages/standalone/current/codex"
pid_file="\$codex_home/app-server-daemon/app-server.pid"
socket_path="\$codex_home/app-server-control/app-server-control.sock"
health_state="\$codex_home/codex-on-vm/remote-control-health.json"

for service in codex-remote-control-bootstrap.service codex-remote-control-health.service; do
  [[ "\$(systemctl show "\$service" --property=KillMode --value)" == "process" ]]
  [[ "\$(systemctl show "\$service" --property=Result --value)" == "success" ]]
  start_monotonic="\$(systemctl show "\$service" --property=ExecMainStartTimestampMonotonic --value)"
  [[ "\$start_monotonic" =~ ^[1-9][0-9]*\$ ]]
  unit_text="\$(systemctl cat "\$service" --no-pager)"
  grep -Fx 'KillMode=process' <<<"\$unit_text" >/dev/null
  grep -Fx "ConditionFileIsExecutable=\$codex_bin" <<<"\$unit_text" >/dev/null
done
systemctl is-active --quiet codex-remote-control-health.timer
[[ -x "\$codex_bin" ]]
[[ -S "\$socket_path" ]]

daemon_version=""
for attempt in 1 2 3 4 5; do
  if candidate="\$(runuser -u "\$admin_user" -- env HOME="\$admin_home" CODEX_HOME="\$codex_home" \
    "\$codex_bin" app-server daemon version 2>/dev/null)" &&
    reported_codex_path="\$(jq -er '
      select(
        .status == "running" and
        (.managedCodexPath | type == "string" and length > 0) and
        (.appServerVersion | type == "string" and length > 0)
      ) | .managedCodexPath
    ' <<<"\$candidate")" &&
    [[ "\$(readlink -f "\$reported_codex_path")" == "\$(readlink -f "\$codex_bin")" ]]; then
    daemon_version="\$candidate"
    break
  fi
  sleep 2
done
[[ -n "\$daemon_version" ]]

remote_control=""
for attempt in 1 2 3 4 5; do
  if candidate="\$(runuser -u "\$admin_user" -- env HOME="\$admin_home" CODEX_HOME="\$codex_home" \
    "\$codex_bin" remote-control start --json 2>/dev/null)" &&
    jq -e '
      .mode == "daemon" and
      .status == "connected" and
      .timedOut == false and
      (.environmentId | type == "string" and length > 0) and
      (.daemon.status | type == "string" and length > 0)
    ' <<<"\$candidate" >/dev/null; then
    remote_control="\$candidate"
    break
  fi
  sleep 2
done
[[ -n "\$remote_control" ]]

pid_before="\$(jq -er '.pid | select(type == "number" and . > 1)' "\$pid_file")"
kill -0 "\$pid_before"
sleep 10
pid_after="\$(jq -er '.pid | select(type == "number" and . > 1)' "\$pid_file")"
[[ "\$pid_after" == "\$pid_before" ]]
kill -0 "\$pid_after"
[[ -S "\$socket_path" ]]
jq -e '
  .consecutiveFailures == 0 and
  .lastRestartEpoch == 0 and
  .restartAttempts == 0
' "\$health_state" >/dev/null

jq -n \
  --arg bootstrapKillMode "\$(systemctl show codex-remote-control-bootstrap.service --property=KillMode --value)" \
  --arg healthKillMode "\$(systemctl show codex-remote-control-health.service --property=KillMode --value)" \
  --arg healthResult "\$(systemctl show codex-remote-control-health.service --property=Result --value)" \
  --arg timerState "\$(systemctl is-active codex-remote-control-health.timer)" \
  --arg appPid "\$pid_after" \
  --arg socketPath "\$socket_path" \
  --arg appServerVersion "\$(jq -r '.appServerVersion' <<<"\$daemon_version")" \
  '{
    bootstrapKillMode: \$bootstrapKillMode,
    healthKillMode: \$healthKillMode,
    healthResult: \$healthResult,
    timerState: \$timerState,
    appPid: \$appPid,
    socketPath: \$socketPath,
    appServerVersion: \$appServerVersion,
    survivedSeconds: 10,
    healthState: "connected-reset"
  }'
printf 'LIVE_SYSTEMD_PROOF=passed\n'
EOF
)"
REMOTE_BODY_B64="$(printf '%s' "$REMOTE_BODY" | base64 | tr -d '\n')"
REMOTE_SCRIPT="printf '%s' '$REMOTE_BODY_B64' | base64 -d | /bin/bash"

RESPONSE="$(az vm run-command invoke \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$REMOTE_SCRIPT" \
  --output json \
  --only-show-errors)"

REMOTE_OUTPUT="$(jq -er '
  [.value[] | .message | select(type == "string" and length > 0)] | last
' <<<"$RESPONSE")" || fail "Azure Run Command returned no stdout"
printf '%s\n' "$REMOTE_OUTPUT"
rg -F 'LIVE_SYSTEMD_PROOF=passed' <<<"$REMOTE_OUTPUT" >/dev/null ||
  fail "live VM did not return the success marker"
printf 'Live systemd boundary: both oneshots executed and the managed daemon survived their exit.\n'
