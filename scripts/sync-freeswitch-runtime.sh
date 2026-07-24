#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX='[sync-freeswitch-runtime]'
API_BASE_FILE='/etc/mnscloud/pabx/api.base'
NODE_UUID_FILE='/etc/mnscloud/pabx/node.uuid'
API_TOKEN_FILE='/etc/mnscloud/pabx/runtime.token'
SOFIA_CONFIG='/etc/freeswitch/autoload_configs/sofia.conf.xml'
FS_CLI="${FREESWITCH_CLI:-fs_cli}"

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

mapfile -t managed_gateways < <(managed_gateway_names "${previous_file}")
for gateway_name in "${managed_gateways[@]}"; do
  log "Replacing managed Sofia gateway: ${gateway_name}"
  # `killgw` removes the local gateway, but an upstream provider may retain
  # its registration until expiry. Ask Sofia to send REGISTER Expires: 0 first.
  unregister_output="$("${FS_CLI}" -x "sofia profile external unregister ${gateway_name}" 2>&1 || true)"
  if grep -Eqi '(^|[[:space:]])-ERR|(^|[[:space:]])ERROR' <<<"${unregister_output}"; then
    fail "Unable to request outbound SIP unregistration for ${gateway_name}: ${unregister_output}"
  fi
  if grep -Eqi 'invalid gateway' <<<"${unregister_output}"; then
    log "Managed Sofia gateway is already absent: ${gateway_name}"
  else
    log "Outbound SIP unregistration requested: ${gateway_name}"
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
