#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX='[sync-freeswitch-runtime]'
API_BASE_FILE='/etc/mnscloud/pabx/api.base'
NODE_UUID_FILE='/etc/mnscloud/pabx/node.uuid'
API_TOKEN_FILE='/etc/mnscloud/pabx/runtime.token'
SOFIA_CONFIG='/etc/freeswitch/autoload_configs/sofia.conf.xml'
FS_CLI="${FREESWITCH_CLI:-fs_cli}"
RETIRED_GATEWAYS="${MNSCLOUD_FREESWITCH_RETIRE_GATEWAYS:-}"

log() { printf '%s %s\n' "${LOG_PREFIX}" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

# Only reconcile dynamically managed gateway names. Other local/external Sofia
# gateways are outside this runtime contract and must never be touched here.
managed_gateway_names() {
  local config_file="$1"

  [[ -r "${config_file}" ]] || return 0
  sed -nE 's/^[[:space:]]*<gateway name="(trunk-[0-9a-f]{32})".*/\1/p' "${config_file}" | sort -u
}

[[ "${EUID}" -eq 0 ]] || fail 'Run this script as root.'
[[ -r "${API_BASE_FILE}" ]] || fail "Missing ${API_BASE_FILE}. Reinstall FreeSWITCH with its runtime command."
[[ -r "${NODE_UUID_FILE}" ]] || fail "Missing ${NODE_UUID_FILE}. Reinstall FreeSWITCH with its runtime command."
[[ -r "${API_TOKEN_FILE}" ]] || fail "Missing ${API_TOKEN_FILE}. Reinstall FreeSWITCH with its runtime command."
command -v curl >/dev/null 2>&1 || fail 'curl is required.'
command -v "${FS_CLI}" >/dev/null 2>&1 || fail "${FS_CLI} is required."

api_base="$(tr -d '[:space:]' < "${API_BASE_FILE}")"
node_uuid="$(tr -d '[:space:]' < "${NODE_UUID_FILE}")"
api_token="$(tr -d '[:space:]' < "${API_TOKEN_FILE}")"
[[ -n "${api_base}" && -n "${node_uuid}" && -n "${api_token}" ]] || fail 'PABX runtime identity is incomplete.'

tmp_file="$(mktemp "${SOFIA_CONFIG}.tmp.XXXXXX")"
previous_file="$(mktemp "${SOFIA_CONFIG}.previous.XXXXXX")"
trap 'rm -f "${tmp_file}" "${previous_file}"' EXIT

log 'Fetching canonical Sofia runtime configuration from the API.'
curl --fail --silent --show-error --retry 2 --connect-timeout 10 --max-time 30 \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --user "mnscloud:${api_token}" \
  --request POST "${api_base%/}/api/v1/pabx/freeswitch" \
  --data-urlencode "node_uuid=${node_uuid}" \
  --data-urlencode 'section=configuration' \
  --data-urlencode 'key_value=sofia.conf' \
  --data-urlencode 'materialize=1' \
  --output "${tmp_file}"

grep -Fq '<configuration name="sofia.conf"' "${tmp_file}" || fail 'API did not return a Sofia configuration document.'
grep -Fq '<profile name="external">' "${tmp_file}" || fail 'API Sofia configuration has no external profile.'

install -d -m 0755 "$(dirname "${SOFIA_CONFIG}")"

# `reloadxml` and `rescan` do not replace an existing Sofia gateway in memory.
# Snapshot the current managed gateway names before replacing the XML, then
# remove only those names so the following rescan materializes the canonical
# API configuration (including changed host, credentials, or deleted trunks).
if [[ -f "${SOFIA_CONFIG}" ]]; then
  cp --preserve=mode "${SOFIA_CONFIG}" "${previous_file}"
fi

# Only a gateway absent from the desired API document is a removal. Existing
# gateways may be refreshed in place, but must not be unregistered during an
# unrelated runtime reconciliation.
mapfile -t previous_managed_gateways < <(managed_gateway_names "${previous_file}")
mapfile -t desired_managed_gateways < <(managed_gateway_names "${tmp_file}")

declare -A desired_gateway_set=()
for gateway_name in "${desired_managed_gateways[@]}"; do
  desired_gateway_set["${gateway_name}"]=1
done

# A registering gateway must finish its SIP unregistration before it can be
# unloaded. Only the Agent's typed retirement job supplies this allow-list.
declare -A retired_gateway_set=()
if [[ -n "${RETIRED_GATEWAYS}" ]]; then
  IFS=',' read -r -a retired_gateway_names <<<"${RETIRED_GATEWAYS}"
  for gateway_name in "${retired_gateway_names[@]}"; do
    [[ "${gateway_name}" =~ ^trunk-[0-9a-f]{32}$ ]] || \
      fail "Invalid explicitly retired gateway name: ${gateway_name}"
    retired_gateway_set["${gateway_name}"]=1
  done
fi

for gateway_name in "${previous_managed_gateways[@]}"; do
  log "Replacing managed Sofia gateway: ${gateway_name}"
  if [[ -z "${desired_gateway_set[${gateway_name}]:-}" ]]; then
    [[ -n "${retired_gateway_set[${gateway_name}]:-}" ]] || \
      fail "Refusing to unload removed gateway ${gateway_name} without Agent-confirmed retirement."
    log "Retiring Agent-confirmed Sofia gateway: ${gateway_name}"
  fi
  "${FS_CLI}" -x "sofia profile external killgw ${gateway_name}" >/dev/null || \
    fail "Unable to remove managed Sofia gateway: ${gateway_name}"
done

chown root:freeswitch "${tmp_file}" 2>/dev/null || chown root:root "${tmp_file}"
chmod 0640 "${tmp_file}"
mv -f "${tmp_file}" "${SOFIA_CONFIG}"
trap - EXIT
rm -f "${previous_file}"

"${FS_CLI}" -x 'reloadxml' >/dev/null
"${FS_CLI}" -x 'sofia profile external rescan' >/dev/null
log 'FreeSWITCH Sofia runtime synchronized and reconciled.'
