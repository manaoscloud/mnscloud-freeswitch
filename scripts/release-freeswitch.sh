#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

find_runtime_kit() {
  local candidate
  for candidate in \
    "${MNSCLOUD_RUNTIME_KIT_DIR:-}" \
    "${ROOT_DIR}/../mnscloud-runtime-kit" \
    "/opt/mnscloud/runtime-kit" \
    "/opt/mnscloud/repos/mnscloud-runtime-kit"; do
    [[ -n "$candidate" && -r "${candidate}/lib/release.sh" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

cd "$ROOT_DIR"
RUNTIME_KIT_DIR="$(find_runtime_kit)" || {
  printf '[mnscloud-freeswitch] ERROR: mnscloud-runtime-kit lib/release.sh not found\n' >&2
  exit 1
}

# shellcheck source=/opt/mnscloud/runtime-kit/lib/release.sh
source "${RUNTIME_KIT_DIR}/lib/release.sh"

mrtk_release_prepare \
  --product mnscloud-freeswitch \
  --repository manaoscloud/mnscloud-freeswitch \
  --minimum-version 0.1.0 \
  --validate 'bash -n scripts/*.sh' \
  "$@"
