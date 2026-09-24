#!/usr/bin/env bash
# Validates that run() waits for apt/dpkg locks before apt commands (stubbed lslocks,
# apt-get and sleep; no root) and exports a transient DPkg::Lock::Timeout APT_CONFIG.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/lslocks" <<STUB
#!/usr/bin/env bash
n=\$(cat "${WORK}/polls" 2>/dev/null || echo 0); echo \$((n + 1)) > "${WORK}/polls"
if (( n < \${HELD_POLLS:-0} )); then echo /var/lib/dpkg/lock-frontend; fi
echo /run/unrelated.lock
STUB
cat > "${WORK}/apt-get" <<STUB
#!/usr/bin/env bash
echo "apt-get \$* | \$(cat "\$APT_CONFIG")" >> "${WORK}/apt-calls"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK}/sleep"
chmod +x "${WORK}/lslocks" "${WORK}/apt-get" "${WORK}/sleep"

run_fixture() {
  rm -f "${WORK}/polls" "${WORK}/apt-calls"
  env -i PATH="${WORK}:/usr/bin:/bin" TMPDIR="${WORK}" HELD_POLLS="$1" REPO="${REPO}" \
    MNSCLOUD_APT_LOCK_TIMEOUT="${2:-600}" bash -c '
      set -euo pipefail
      LOG_PREFIX="[fixture]"
      DRY_RUN=false
      # shellcheck disable=SC1091
      source "${REPO}/scripts/lib/install-base.sh"
      run "echo not-apt-marker"
      run "apt-get install -y --no-install-recommends curl"
    '
}

out="$(run_fixture 3)"
grep -q "Waiting for another apt/dpkg process" <<<"$out" || { echo "FAIL: no wait message"; exit 1; }
[[ "$(cat "${WORK}/polls")" == "4" ]] || { echo "FAIL: expected 4 lock polls, got $(cat "${WORK}/polls")"; exit 1; }
grep -q 'apt-get install -y --no-install-recommends curl | DPkg::Lock::Timeout "600";' "${WORK}/apt-calls" ||
  { echo "FAIL: apt-get not called with lock timeout config"; exit 1; }

out="$(run_fixture 0)"
! grep -q "Waiting for another" <<<"$out" || { echo "FAIL: waited without a held lock"; exit 1; }
[[ "$(cat "${WORK}/polls")" == "1" ]] || { echo "FAIL: non-apt command polled locks"; exit 1; }

out="$(run_fixture 1000 10 2>&1)"
grep -q "still held after 10s" <<<"$out" || { echo "FAIL: timeout warning missing"; exit 1; }
grep -q 'DPkg::Lock::Timeout "10";' "${WORK}/apt-calls" || { echo "FAIL: apt-get not run after timeout"; exit 1; }

echo "PASS: apt/dpkg lock wait contract"
