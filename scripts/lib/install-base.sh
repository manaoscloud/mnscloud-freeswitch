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

log_raw() { printf "[%s] %s %s\n" "$(_ts)" "$1" "$2" >> "$LOG_FILE" || true; }

log() {
  local lvl="$1"; shift
  local msg="$*"

  case "$lvl" in
    INFO) echo -e "${LOG_PREFIX} \033[1;32mINFO\033[0m  ${msg}" ;;
    WARN) echo -e "${LOG_PREFIX} \033[1;33mWARN\033[0m  ${msg}" ;;
    ERROR) echo -e "${LOG_PREFIX} \033[1;31mERROR\033[0m ${msg}" ;;
    OK) echo -e "${LOG_PREFIX} \033[1;36mOK\033[0m    ${msg}" ;;
    DRY) echo -e "${LOG_PREFIX} \033[1;35mDRY-RUN\033[0m ${msg}" ;;
    *) echo -e "${LOG_PREFIX} ${msg}" ;;
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

  if $DRY_RUN; then
    log DRY "$cmd"
    return 0
  fi

  info "RUN: $cmd"
  set +e
  bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE"
  local rc="${PIPESTATUS[0]}"
  set -e

  if [[ "$rc" -ne 0 ]]; then
    err "Failed (exit=${rc}): $cmd"
    return "$rc"
  fi
  return 0
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
      run "apt-get install -y --no-install-recommends wget git curl make man-db manpages htop bash-completion nano screen ripgrep"
      ;;
    rocky)
      pkg_update
      # EPEL provides ripgrep and other useful utilities on Rocky/RHEL.
      run "dnf -y install epel-release"
      run "dnf -y makecache"
      # Current baseline: you can add more items here in the future
      run "dnf -y install wget git curl make man-db htop bash-completion nano screen ripgrep || true"
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
