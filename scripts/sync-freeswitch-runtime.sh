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
trap 'rm -f "${tmp_file}"' EXIT

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
chown root:freeswitch "${tmp_file}" 2>/dev/null || chown root:root "${tmp_file}"
chmod 0640 "${tmp_file}"
mv -f "${tmp_file}" "${SOFIA_CONFIG}"
trap - EXIT

"${FS_CLI}" -x 'reloadxml' >/dev/null
"${FS_CLI}" -x 'sofia profile external rescan' >/dev/null
log 'FreeSWITCH Sofia runtime synchronized and rescanned.'
