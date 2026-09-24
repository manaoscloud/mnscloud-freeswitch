#!/usr/bin/env bash
set -euo pipefail

# ---------- Args ----------
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
  esac
done

# ---------- Defaults ----------
LOG_PREFIX="${LOG_PREFIX:-[install]}"

DEFAULT_LOG_FILE="./mnscloud-install.log"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  DEFAULT_LOG_FILE="/var/log/mnscloud-install.log"
fi
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"

_ts() { date +"%Y-%m-%d %H:%M:%S"; }

# Set to 1 by install_log_capture_start once stdout/stderr of the whole
# session are mirrored into LOG_FILE.
MNSCLOUD_LOG_CAPTURED="${MNSCLOUD_LOG_CAPTURED:-0}"
MNSCLOUD_LAST_ERR=""
MNSCLOUD_LAST_ERR_LOCKED=0
MNSCLOUD_LOG_SECRETS=()

# Secrets registered here are masked in every RUN/failure line written to the log.
register_log_secret() {
  local value="${1:-}"
  [[ ${#value} -ge 6 ]] || return 0
  MNSCLOUD_LOG_SECRETS+=("${value}")
}

redact_log_text() {
  local text="$1" secret
  for secret in ${MNSCLOUD_LOG_SECRETS[@]+"${MNSCLOUD_LOG_SECRETS[@]}"}; do
    text="${text//"${secret}"/***}"
  done
  printf '%s' "${text}"
}

log_raw() {
  # With session capture active, the stdout line already reaches LOG_FILE.
  [[ "${MNSCLOUD_LOG_CAPTURED}" == "1" ]] && return 0
  printf "[%s] %s %s\n" "$(_ts)" "$1" "$2" >> "$LOG_FILE" || true
}

log() {
  local lvl="$1"; shift
  local msg="$*" stamp=""

  [[ "${MNSCLOUD_LOG_CAPTURED}" == "1" ]] && stamp="[$(_ts)] "

  case "$lvl" in
    INFO) echo -e "${stamp}${LOG_PREFIX} \033[1;32mINFO\033[0m  ${msg}" ;;
    WARN) echo -e "${stamp}${LOG_PREFIX} \033[1;33mWARN\033[0m  ${msg}" ;;
    ERROR) echo -e "${stamp}${LOG_PREFIX} \033[1;31mERROR\033[0m ${msg}" ;;
    OK) echo -e "${stamp}${LOG_PREFIX} \033[1;36mOK\033[0m    ${msg}" ;;
    DRY) echo -e "${stamp}${LOG_PREFIX} \033[1;35mDRY-RUN\033[0m ${msg}" ;;
    *) echo -e "${stamp}${LOG_PREFIX} ${lvl} ${msg}" ;;
  esac

  log_raw "$lvl" "$msg"
}

info() { log INFO "$*"; }
warn() { log WARN "$*"; }
err()  { log ERROR "$*"; }
ok()   { log OK "$*"; }

banner() {
  local title="${1:-Installer}"
  local subtitle="${2:-}"
  echo "=================================================="
  echo "${title}"
  [[ -n "$subtitle" ]] && echo "${subtitle}"
  echo "Mode: $( $DRY_RUN && echo "DRY-RUN" || echo "APPLY" )"
  echo "Log:  ${LOG_FILE}"
  echo "=================================================="
  log_raw "START" "$title"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run as root (for example: sudo bash $0)"
    exit 1
  fi
}

ensure_local_hostname_hosts() {
  local hosts_file="${1:-/etc/hosts}"
  local short_name fqdn aliases=() value tmp_file

  short_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  fqdn="$(hostname -f 2>/dev/null || true)"

  [[ -n "${short_name}" ]] || {
    warn "Local hostname is empty; /etc/hosts was not adjusted."
    return 0
  }

  aliases+=("${short_name}")
  if [[ -n "${fqdn}" && "${fqdn}" != "${short_name}" && "${fqdn}" != "localhost" && "${fqdn}" == *.* ]]; then
    aliases+=("${fqdn}")
  fi

  mapfile -t aliases < <(printf "%s\n" "${aliases[@]}" | awk 'NF && !seen[$0]++')

  if $DRY_RUN; then
    log DRY "ensure local hostname in ${hosts_file}: ${aliases[*]}"
    return 0
  fi

  tmp_file="$(mktemp)"
  if [[ -f "${hosts_file}" ]]; then
    awk '
      /^# BEGIN mnscloud local hostname$/ { skip=1; next }
      /^# END mnscloud local hostname$/ { skip=0; next }
      !skip { print }
    ' "${hosts_file}" > "${tmp_file}"
  fi

  {
    printf "\n# BEGIN mnscloud local hostname\n"
    printf "127.0.1.1"
    for value in "${aliases[@]}"; do printf " %s" "${value}"; done
    printf "\n"
    printf "::1"
    for value in "${aliases[@]}"; do printf " %s" "${value}"; done
    printf "\n# END mnscloud local hostname\n"
  } >> "${tmp_file}"

  cat "${tmp_file}" > "${hosts_file}"
  rm -f "${tmp_file}"
  ok "Local hostname ensured in ${hosts_file}: ${aliases[*]}"
}

run() {
  local cmd="$*"

  local shown
  shown="$(redact_log_text "$cmd")"
  if $DRY_RUN; then
    log DRY "$shown"
    return 0
  fi

  info "RUN: $shown"
  MNSCLOUD_LAST_ERR_LOCKED=0
  local started rc
  started="$(date +%s)"
  set +e
  if [[ "${MNSCLOUD_LOG_CAPTURED}" == "1" ]]; then
    bash -c "$cmd" 2>&1
    rc=$?
  else
    bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
  fi
  set -e

  if [[ "$rc" -ne 0 ]]; then
    err "Failed (exit=${rc}, $(( $(date +%s) - started ))s): $shown"
    MNSCLOUD_LAST_ERR="exit=${rc}: ${shown}"
    MNSCLOUD_LAST_ERR_LOCKED=1
    return "$rc"
  fi
  return 0
}

# ==========================================================
# Full session logging
#   Mirrors every stdout/stderr line of the installer (including child
#   builds) into LOG_FILE, records host context, and on failure writes the
#   failing command plus resource diagnostics so nothing stays hidden.
#   Installers may define install_failure_diagnostics() for module-specific
#   evidence; it runs before the generic diagnostics.
# ==========================================================
MNSCLOUD_INSTALL_STARTED_AT=""
MNSCLOUD_LOG_TEE_PID=""

install_log_capture_start() {
  local label="${1:-installer}"
  MNSCLOUD_INSTALL_STARTED_AT="$(date +%s)"

  if [[ "${MNSCLOUD_LOG_CAPTURED}" != "1" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" && chmod 0640 "$LOG_FILE" 2>/dev/null || true
    # Terminal keeps colors; the log file gets the same lines without ANSI codes.
    exec > >(tee >(sed -u -E 's/\x1B\[[0-9;]*[A-Za-z]//g' >>"$LOG_FILE")) 2>&1
    MNSCLOUD_LOG_TEE_PID=$!
    MNSCLOUD_LOG_CAPTURED=1
  fi

  set -E
  # run() records its own failing command; other failures keep file line/function.
  trap '[[ "${MNSCLOUD_LAST_ERR_LOCKED}" == "1" || "${BASH_COMMAND}" == return* ]] || MNSCLOUD_LAST_ERR="line ${LINENO} in ${FUNCNAME[0]:-main}: ${BASH_COMMAND}"' ERR
  trap '_install_log_finish $?' EXIT

  echo "=================================================================="
  log START "${label} (pid $$)"
  install_log_host_context
  echo "=================================================================="
}

install_log_host_context() {
  local mem_total mem_avail swap_total
  mem_total="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo '?')"
  mem_avail="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo '?')"
  swap_total="$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo '?')"
  info "Context: host=$(hostname -f 2>/dev/null || hostname) os=\"$(os_label)\" kernel=$(uname -r) arch=$(uname -m)"
  info "Context: cpus=$(nproc 2>/dev/null || echo '?') mem_total=${mem_total}MB mem_available=${mem_avail}MB swap=${swap_total}MB bash=${BASH_VERSION}"
  info "Context: disk $(df -hP / 2>/dev/null | awk 'NR==2 {print $1" size="$2" used="$3" avail="$4" mounted="$6}')"
  info "Context: mode=$( $DRY_RUN && echo DRY-RUN || echo APPLY ) log=${LOG_FILE}"
}

install_log_generic_diagnostics() {
  echo "----- diagnostics: resources -----"
  free -m 2>&1 || true
  df -hP 2>&1 || true
  uptime 2>&1 || true
  echo "----- diagnostics: kernel OOM / kill events since install start -----"
  if command -v journalctl >/dev/null 2>&1 && [[ -n "${MNSCLOUD_INSTALL_STARTED_AT}" ]]; then
    journalctl -k --no-pager --since "@${MNSCLOUD_INSTALL_STARTED_AT}" 2>&1 |
      grep -iE 'out of memory|oom|killed process|segfault|i/o error' | tail -n 30 || echo "(none)"
  else
    dmesg 2>&1 | grep -iE 'out of memory|oom|killed process|segfault|i/o error' | tail -n 30 || echo "(none)"
  fi
  echo "----- diagnostics: failed systemd units -----"
  systemctl --failed --no-legend --no-pager 2>&1 || true
}

_install_log_finish() {
  local rc="$1" elapsed=0
  trap - EXIT ERR
  set +e
  [[ -n "${MNSCLOUD_INSTALL_STARTED_AT}" ]] && elapsed=$(( $(date +%s) - MNSCLOUD_INSTALL_STARTED_AT ))

  if [[ "$rc" -ne 0 ]]; then
    err "Installer failed (exit=${rc}) after ${elapsed}s."
    [[ -n "${MNSCLOUD_LAST_ERR}" ]] && err "Last failed command: ${MNSCLOUD_LAST_ERR}"
    if declare -F install_failure_diagnostics >/dev/null; then
      install_failure_diagnostics
    fi
    install_log_generic_diagnostics
    log END "FAILED exit=${rc} elapsed=${elapsed}s log=${LOG_FILE}"
  else
    log END "OK elapsed=${elapsed}s log=${LOG_FILE}"
  fi

  # Flush the tee pipeline before the process exits so the log is complete.
  if [[ -n "${MNSCLOUD_LOG_TEE_PID}" ]]; then
    # Bounded wait: a leftover child holding stdout must not hang the exit.
    exec 1>&- 2>&-
    local waited=0
    while kill -0 "${MNSCLOUD_LOG_TEE_PID}" 2>/dev/null && (( waited < 50 )); do
      sleep 0.1
      waited=$(( waited + 1 ))
    done
  fi
  exit "$rc"
}

run_script() {
  local script="$1"
  shift || true
  run "bash ${script} $*"
}

write_file() {
  local path="$1"
  local content="$2"

  if $DRY_RUN; then
    log DRY "write ${path}"
    return 0
  fi

  info "WRITE: ${path}"
  printf "%s\n" "$content" > "$path"
  ok "File updated: ${path}"
}

# ==========================================================
# ✅ Shared OS support (ONLY):
#   - Debian 12/13
#   - Rocky 8/9
# ==========================================================
detect_supported_os() {
  if [[ ! -r /etc/os-release ]]; then
    err "Could not read /etc/os-release"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    debian)
      if [[ "${VERSION_ID:-}" == "12" || "${VERSION_ID:-}" == "13" ]]; then
        echo "debian"
        return 0
      fi
      ;;
    rocky)
      case "${VERSION_ID:-}" in
        8*|9*)
        echo "rocky"
        return 0
        ;;
      esac
      ;;
  esac

  echo "unsupported"
}

# ==========================================================
# ✅ Human-friendly OS label (reusable)
# ==========================================================
os_label() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    local id="${ID:-unknown}" ver="${VERSION_ID:-unknown}"
    case "$id:$ver" in
      debian:12) echo "Debian 12" ;;
      debian:13) echo "Debian 13" ;;
      rocky:8* ) echo "Rocky Linux 8" ;;
      rocky:9* ) echo "Rocky Linux 9" ;;
      *) echo "${id} ${ver}" ;;
    esac
  else
    echo "unknown"
  fi
}

# ==========================================================
# ✅ Generic package metadata update (APT/DNF)
# ==========================================================
pkg_update() {
  local os
  os="$(detect_supported_os)"
  case "$os" in
    debian) run "apt-get update -y" ;;
    rocky)  run "dnf -y makecache" ;;
    *)
      err "Unsupported operating system for pkg_update(). Supported: Debian 12/13 and Rocky 8/9."
      return 2
      ;;
  esac
}

# ==========================================================
# ✅ Project dependencies installer (GENERIC)
#   (keeps compatibility with Debian 12/13 and Rocky 8/9)
# ==========================================================
install_project_deps() {
  local os
  os="$(detect_supported_os)"

  info "Installing project dependencies (common tools & build deps)..."

  case "$os" in
    debian)
      pkg_update
      # Current baseline: you can add more items here in the future
      run "apt-get install -y --no-install-recommends wget git curl make man-db manpages htop bash-completion nano screen ripgrep poppler-utils"
      ;;
    rocky)
      pkg_update
      # EPEL provides ripgrep and other useful utilities on Rocky/RHEL.
      run "dnf -y install epel-release"
      run "dnf -y makecache"
      # Current baseline: you can add more items here in the future
      run "dnf -y install wget git curl make man-db htop bash-completion nano screen ripgrep poppler-utils || true"
      run "dnf -y install man-pages || true"
      ;;
    *)
      err "Unsupported operating system for install_project_deps(). Supported: Debian 12/13 and Rocky 8/9."
      return 2
      ;;
  esac

  enable_bash_completion
  ok "Project dependencies installed (or already present)."
}

# ==========================================================
# ✅ Bash completion enable (system-wide)
#   (includes Makefile autocomplete)
# ==========================================================
enable_bash_completion() {
  local content
  content=$'# MNSCloud: enable bash completion\nif [ -f /usr/share/bash-completion/bash_completion ]; then\n  . /usr/share/bash-completion/bash_completion\nelif [ -f /etc/bash_completion ]; then\n  . /etc/bash_completion\nfi\n\nif declare -F _make >/dev/null 2>&1; then\n  complete -F _make make 2>/dev/null || true\nfi'
  write_file "/etc/profile.d/mnscloud-bash-completion.sh" "$content"
  ensure_bashrc_completion
  ok "Bash completion enabled (make autocomplete)."
}

# Ensure interactive shells load /etc/bash_completion (Debian/Rocky).
ensure_bashrc_completion() {
  local bashrc marker block
  if [[ -f /etc/bash.bashrc ]]; then
    bashrc="/etc/bash.bashrc"
  elif [[ -f /etc/bashrc ]]; then
    bashrc="/etc/bashrc"
  else
    return 0
  fi

  marker="# MNSCloud: enable bash completion (system)"
  block=$'\n# MNSCloud: enable bash completion (system)\nif [ -f /etc/bash_completion ]; then\n  . /etc/bash_completion\nfi\n'

  if ! grep -qF "${marker}" "${bashrc}"; then
    run "printf '%s' '${block}' >> '${bashrc}'"
  fi
}

# ==========================================================
# ✅ Bash completion installer (minimal)
# ==========================================================
install_bash_completion() {
  local os
  os="$(detect_supported_os)"

  info "Instalando bash-completion..."

  case "$os" in
    debian) run "apt-get install -y --no-install-recommends bash-completion" ;;
    rocky)  run "dnf -y install bash-completion || true" ;;
    *)
      err "Unsupported operating system for install_bash_completion(). Supported: Debian 12/13 and Rocky 8/9."
      return 2
      ;;
  esac

  enable_bash_completion
  ok "bash-completion installed and enabled."
}
