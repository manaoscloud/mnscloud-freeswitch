#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REF=''
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/update-freeswitch.sh --ref <release-tag-or-commit> [--dry-run]

Updates this FreeSWITCH runtime to an explicit approved ref. The local PABX
identity in /etc/mnscloud/pabx is preserved. If installation or validation
fails, the previous checkout is restored and reapplied before this command
returns an error.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf '[update-freeswitch] ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$REF" ]] || { printf '[update-freeswitch] ERROR: --ref is required\n' >&2; usage >&2; exit 2; }
[[ "$REF" =~ ^[A-Za-z0-9._/@+-]+$ ]] || { printf '[update-freeswitch] ERROR: invalid ref: %s\n' "$REF" >&2; exit 2; }
[[ "${EUID}" -eq 0 ]] || { printf '[update-freeswitch] ERROR: run as root\n' >&2; exit 1; }

cd "$ROOT_DIR"
if [[ "$DRY_RUN" == '1' ]]; then
  printf '[update-freeswitch] DRY-RUN: fetch, checkout %s, install, and validate FreeSWITCH\n' "$REF"
  bash "${SCRIPT_DIR}/validate-freeswitch.sh" 2>/dev/null || true
  exit 0
fi

git fetch --prune origin main '+refs/tags/*:refs/tags/*'

is_lifecycle_bootstrap_path() {
  case "$1" in
    scripts/update-freeswitch.sh|scripts/update-latest-freeswitch.sh|scripts/validate-freeswitch.sh|scripts/rollback-freeswitch.sh)
      return 0
      ;;
    *) return 1 ;;
  esac
}

assert_checkout_is_safe_to_update() {
  local entry path
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    path="${entry:3}"
    if is_lifecycle_bootstrap_path "$path" && \
      git diff --quiet origin/main -- "$path" && \
      git diff --cached --quiet origin/main -- "$path"; then
      continue
    fi
    printf '[update-freeswitch] ERROR: local repository change detected: %s. Commit, stash, or discard it before updating.\n' "$path" >&2
    return 1
  done < <(git status --porcelain)
}

# Older installs bootstrap the lifecycle scripts directly from origin/main. Those
# exact upstream files are safe to carry into the first tag checkout; every
# other local modification remains a hard stop.
assert_checkout_is_safe_to_update

previous_ref="$(git rev-parse HEAD)"
git rev-parse --verify --quiet "${REF}^{commit}" >/dev/null || {
  printf '[update-freeswitch] ERROR: ref not found: %s\n' "$REF" >&2
  exit 1
}

restore_previous() {
  local result=0
  printf '[update-freeswitch] restoring previous runtime ref: %s\n' "$previous_ref" >&2
  git -c advice.detachedHead=false checkout --detach "$previous_ref" || result=1
  if [[ "$result" == '0' ]]; then
    bash "${SCRIPT_DIR}/install-freeswitch.sh" || result=1
    bash "${SCRIPT_DIR}/validate-freeswitch.sh" || result=1
  fi
  return "$result"
}

printf '[update-freeswitch] applying FreeSWITCH runtime ref: %s\n' "$REF"
git -c advice.detachedHead=false checkout --detach "$REF"
if ! bash "${SCRIPT_DIR}/install-freeswitch.sh"; then
  restore_previous || true
  printf '[update-freeswitch] ERROR: update installation failed; previous runtime was restored.\n' >&2
  exit 1
fi
if ! bash "${SCRIPT_DIR}/validate-freeswitch.sh"; then
  restore_previous || true
  printf '[update-freeswitch] ERROR: update validation failed; previous runtime was restored.\n' >&2
  exit 1
fi

printf '[update-freeswitch] update completed: %s\n' "$REF"
