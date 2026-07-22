#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHANNEL='stable'
DEFAULT_API_BASE='https://dev.publichost.cloud/api/v1'
API_BASE="${MNSCLOUD_RELEASE_API_BASE_URL:-${MNSCLOUD_API_BASE_URL:-${API_BASE_URL:-$DEFAULT_API_BASE}}}"
PRINT_COMMAND=0

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/update-latest-freeswitch.sh [--api-base <api-v1-url>] [--channel stable] [--print-command]

Resolves the latest approved FreeSWITCH release from the MNSCloud control
plane. If this product is not yet in the registry, it falls back to the latest
semantic-version tag published by this repository.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-base) API_BASE="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --print-command) PRINT_COMMAND=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf '[update-latest-freeswitch] ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "${MNSCLOUD_RELEASE_API_BASE_URL:-}" && -z "${MNSCLOUD_API_BASE_URL:-}" && -z "${API_BASE_URL:-}" && -s /etc/mnscloud/pabx/api.base ]]; then
  API_BASE="$(tr -d '[:space:]' < /etc/mnscloud/pabx/api.base)"
fi

resolve_ref() {
  local normalized_api_base="$API_BASE" ref
  normalized_api_base="${normalized_api_base%/}"
  [[ "$normalized_api_base" == */api/v1 ]] || normalized_api_base="${normalized_api_base}/api/v1"
  ref="$(
    MNSCLOUD_RELEASE_URL="${normalized_api_base}/runtime/releases/latest?product=mnscloud-freeswitch&channel=${CHANNEL}" python3 <<'PY' 2>/dev/null || true
import json
import os
import urllib.request

with urllib.request.urlopen(os.environ['MNSCLOUD_RELEASE_URL'], timeout=10) as response:
    payload = json.loads(response.read().decode('utf-8')).get('data') or {}
print(payload.get('ref') or '')
PY
  )"
  if [[ -n "$ref" ]]; then
    printf '%s\n' "$ref"
    return 0
  fi
  git -C "$ROOT_DIR" fetch --prune origin main '+refs/tags/*:refs/tags/*'
  git -C "$ROOT_DIR" tag -l 'v*' --sort=-v:refname | head -n1
}

REF="$(resolve_ref)"
[[ "$REF" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || {
  printf '[update-latest-freeswitch] ERROR: invalid latest %s ref: %s\n' "$CHANNEL" "${REF:-empty}" >&2
  exit 1
}

printf '[update-latest-freeswitch] latest release: %s\n' "$REF"
if [[ "$PRINT_COMMAND" == '1' ]]; then
  printf 'cd %s\nsudo ./scripts/update-latest-freeswitch.sh\n' "$ROOT_DIR"
  exit 0
fi

bash "${SCRIPT_DIR}/update-freeswitch.sh" --ref "$REF"
