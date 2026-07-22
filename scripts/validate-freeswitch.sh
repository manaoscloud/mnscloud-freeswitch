#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOFIA_CONFIG="${FREESWITCH_SOFIA_CONFIG:-/etc/freeswitch/autoload_configs/sofia.conf.xml}"
FS_CLI="${FREESWITCH_CLI:-fs_cli}"

fail() {
  printf '[validate-freeswitch] ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -s "$path" ]] || fail "required runtime state is missing or empty: ${path}"
}

printf '[validate-freeswitch] checking shell scripts\n'
for script in \
  "${SCRIPT_DIR}"/*.sh \
  "${SCRIPT_DIR}"/lib/*.sh; do
  bash -n "$script"
done

[[ "${EUID}" -eq 0 ]] || fail 'run this validation as root.'
command -v systemctl >/dev/null 2>&1 || fail 'systemctl is required.'
command -v "$FS_CLI" >/dev/null 2>&1 || fail "${FS_CLI} is required."

require_file '/etc/mnscloud/pabx/api.base'
require_file '/etc/mnscloud/pabx/node.uuid'
require_file '/etc/mnscloud/pabx/runtime.token'
require_file "$SOFIA_CONFIG"

grep -Fq '<configuration name="sofia.conf"' "$SOFIA_CONFIG" || fail "invalid Sofia configuration: ${SOFIA_CONFIG}"
grep -Fq '<profile name="external">' "$SOFIA_CONFIG" || fail "Sofia external profile is missing: ${SOFIA_CONFIG}"

systemctl is-active --quiet freeswitch || fail 'freeswitch.service is not active.'
"${FS_CLI}" -x status >/dev/null || fail 'fs_cli cannot query FreeSWITCH status.'
external_profile_status="$("${FS_CLI}" -x 'sofia status profile external')" || fail 'the external Sofia profile is unavailable.'
printf '%s\n' "$external_profile_status" | grep -qi 'external' || fail 'the external Sofia profile did not report a valid status.'

printf '[validate-freeswitch] FreeSWITCH runtime validation OK\n'
