#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/rollback-freeswitch.sh --ref <known-good-release-tag-or-commit>

Rolls FreeSWITCH back to an explicit known-good ref, reapplies managed runtime
configuration, and validates the running service.
USAGE
}

REF=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf '[rollback-freeswitch] ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$REF" ]] || { printf '[rollback-freeswitch] ERROR: --ref is required\n' >&2; usage >&2; exit 2; }
exec bash "${SCRIPT_DIR}/update-freeswitch.sh" --ref "$REF"
