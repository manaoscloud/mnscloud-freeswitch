#!/usr/bin/env bash
# Validates the installer session logging contract in scripts/lib/install-base.sh:
# full stdout/stderr capture without ANSI codes, START/END markers, preserved
# exit codes, failing command attribution, and failure diagnostics.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/fixture.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
LOG_PREFIX="[fixture]"
# shellcheck disable=SC1091
source "${REPO}/scripts/lib/install-base.sh"
install_failure_diagnostics() { echo "module-diagnostics-marker"; }
install_log_capture_start "fixture"
echo "plain-stdout-marker"
run "echo child-stdout-marker; echo child-stderr-marker >&2"
ok "success-marker"
if [[ "${MODE}" == "fail" ]]; then
  run "echo before-failure; exit 7"
fi
ok "completed-marker"
FIXTURE

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { grep -qF -- "$2" "$1" || fail "missing '$2' in $1"; }
reject() { ! grep -qF -- "$2" "$1" || fail "unexpected '$2' in $1"; }

# Success path
LOG_FILE="${WORK}/ok.log" MODE=ok REPO="${REPO}" bash "${WORK}/fixture.sh" >"${WORK}/ok.out" 2>&1 ||
  fail "success fixture returned non-zero"
for marker in "START fixture" "Context: cpus=" plain-stdout-marker child-stdout-marker \
  child-stderr-marker success-marker completed-marker "END OK"; do
  expect "${WORK}/ok.log" "${marker}"
done
[[ "$(grep -cx "child-stdout-marker" "${WORK}/ok.log")" == "1" ]] || fail "command output duplicated in log"
! grep -q $'\x1b' "${WORK}/ok.log" || fail "ANSI escape codes leaked into log"
[[ "$(stat -c %a "${WORK}/ok.log")" == "640" ]] || fail "log file mode is not 0640"

# Failure path
set +e
LOG_FILE="${WORK}/fail.log" MODE=fail REPO="${REPO}" bash "${WORK}/fixture.sh" >"${WORK}/fail.out" 2>&1
rc=$?
set -e
[[ "${rc}" == "7" ]] || fail "failure exit code not preserved (got ${rc})"
for marker in before-failure "Failed (exit=7" "Last failed command: exit=7: echo before-failure; exit 7" \
  module-diagnostics-marker "diagnostics: resources" "END FAILED exit=7"; do
  expect "${WORK}/fail.log" "${marker}"
done
reject "${WORK}/fail.log" completed-marker

printf 'install-log-capture: OK\n'
