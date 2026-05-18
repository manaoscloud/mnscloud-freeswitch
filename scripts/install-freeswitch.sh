#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[install-freeswitch]"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/install-base.sh" "$@"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/env.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${MNSCLOUD_MONOREPO_ROOT:-${PROJECT_ROOT}}/.env"

# ==========================================================
# Configuration variables
# ==========================================================
NODE_UUID_FILE="/etc/mnscloud/pabx/node.uuid"
API_TOKEN_FILE="/etc/mnscloud/pabx/api.token"
API_BASE_FILE="/etc/mnscloud/pabx/api.base"
SIGNALWIRE_REPO_TOKEN_FILE="/etc/mnscloud/pabx/signalwire-repo.token"
DEFAULT_API_BASE="https://api.publichost.cloud"
NODE_UUID=""
API_BASE=""
TOKEN=""
API_TOKEN=""
FS_DB_HOST="${FS_DB_HOST:-${DB_HOST:-}}"
FS_DB_PORT="${FS_DB_PORT:-${DB_PORT:-3306}}"
FS_DB_NAME="${FS_DB_NAME:-${DB_NAME:-}}"
FS_DB_USER="${FS_DB_USER:-${DB_USER:-}}"
FS_DB_PASS="${FS_DB_PASS:-${DB_PASS:-}}"
FS_LOCAL_IP="${FREESWITCH_LOCAL_IP:-}"
FS_EXT_SIP_IP="${FREESWITCH_EXT_SIP_IP:-auto-nat}"
FS_EXT_RTP_IP="${FREESWITCH_EXT_RTP_IP:-auto-nat}"
FS_AUTO_DISCOVER_PUBLIC_IP="${FREESWITCH_AUTO_DISCOVER_PUBLIC_IP:-1}"
FS_CONTROL_PORT="8021"
FS_CONTROL_LISTEN_IP="0.0.0.0"
FS_CONTROL_ALLOWED_IPS=""
FS_CONTROL_SECRET_FILE="/etc/mnscloud/pabx/freeswitch-esl.secret"
FS_CONTROL_SECRET=""
API_VALIDATED_PUBLIC_IP=""
BCG729_SOURCE_URL="${FREESWITCH_BCG729_SOURCE_URL:-https://github.com/xadhoom/mod_bcg729.git}"
BCG729_SOURCE_REF="${FREESWITCH_BCG729_SOURCE_REF:-4203247dee4719545005ec7ab9ea536fc83df1d8}"
BCG729_BUILD_DIR="${FREESWITCH_BCG729_BUILD_DIR:-/usr/src/mnscloud-mod-bcg729}"
BCG729_BUNDLED_SOURCE_DIR="${FREESWITCH_BCG729_BUNDLED_SOURCE_DIR:-${PROJECT_ROOT}/codecs/mod_bcg729}"

load_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    info "Loading variables from ${ENV_FILE}"

    local env_db_host env_db_port env_db_name env_db_user env_db_pass env_fs_local_ip
    env_db_host="$(read_env_var "${ENV_FILE}" "DB_HOST")"
    env_db_port="$(read_env_var "${ENV_FILE}" "DB_PORT")"
    env_db_name="$(read_env_var "${ENV_FILE}" "DB_NAME")"
    env_db_user="$(read_env_var "${ENV_FILE}" "DB_USER")"
    env_db_pass="$(read_env_var "${ENV_FILE}" "DB_PASS")"
    env_fs_local_ip="$(read_env_var "${ENV_FILE}" "FREESWITCH_LOCAL_IP")"

    # Reassigns after loading .env (does not override explicit values)
    FS_DB_HOST="${FS_DB_HOST:-${DB_HOST:-${FS_DB_HOST}}}"
    FS_DB_HOST="${FS_DB_HOST:-${env_db_host}}"
    FS_DB_PORT="${FS_DB_PORT:-${DB_PORT:-${FS_DB_PORT}}}"
    FS_DB_PORT="${FS_DB_PORT:-${env_db_port}}"
    FS_DB_NAME="${FS_DB_NAME:-${DB_NAME:-${FS_DB_NAME}}}"
    FS_DB_NAME="${FS_DB_NAME:-${env_db_name}}"
    FS_DB_USER="${FS_DB_USER:-${DB_USER:-${FS_DB_USER}}}"
    FS_DB_USER="${FS_DB_USER:-${env_db_user}}"
    FS_DB_PASS="${FS_DB_PASS:-${DB_PASS:-${FS_DB_PASS}}}"
    FS_DB_PASS="${FS_DB_PASS:-${env_db_pass}}"
    FS_LOCAL_IP="${FREESWITCH_LOCAL_IP:-${FS_LOCAL_IP}}"
    FS_LOCAL_IP="${FS_LOCAL_IP:-${env_fs_local_ip}}"
    FS_EXT_SIP_IP="${FREESWITCH_EXT_SIP_IP:-${FS_EXT_SIP_IP}}"
    FS_EXT_RTP_IP="${FREESWITCH_EXT_RTP_IP:-${FS_EXT_RTP_IP}}"
    FS_AUTO_DISCOVER_PUBLIC_IP="${FREESWITCH_AUTO_DISCOVER_PUBLIC_IP:-${FS_AUTO_DISCOVER_PUBLIC_IP}}"
  fi
}

normalize_url() {
  local value="$1"
  value="$(printf "%s" "$value" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s#/*$##')"
  printf "%s" "$value"
}

validate_api_base() {
  [[ "$1" =~ ^https?://[^[:space:]/]+(:[0-9]+)?(/[^[:space:]]*)?$ ]]
}

prompt_api_base() {
  local value=""
  if [[ -t 0 ]]; then
    read -r -p "Enter the MNSCloud API base URL [${DEFAULT_API_BASE}]: " value
  fi
  value="${value:-${DEFAULT_API_BASE}}"
  normalize_url "$value"
}

ensure_api_base_file() {
  local dir value
  dir="$(dirname "${API_BASE_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"

  if [[ -f "${API_BASE_FILE}" ]]; then
    value="$(tr -d '[:space:]' < "${API_BASE_FILE}")"
    API_BASE="$(normalize_url "$value")"
    ok "API base carregada de ${API_BASE_FILE}: ${API_BASE}"
  else
    API_BASE="$(prompt_api_base)"
    validate_api_base "${API_BASE}" || { err "URL base da API invalida: ${API_BASE}"; return 1; }
    write_file "${API_BASE_FILE}" "${API_BASE}"
    ok "API base saved to ${API_BASE_FILE}: ${API_BASE}"
  fi

  validate_api_base "${API_BASE}" || { err "URL base da API invalida em ${API_BASE_FILE}: ${API_BASE}"; return 1; }
  run "chown root:root '${API_BASE_FILE}'"
  run "chmod 0640 '${API_BASE_FILE}'"
}

prompt_secret_value() {
  local label="$1" value=""
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf "%s: " "${label}" >/dev/tty
    IFS= read -r value </dev/tty
  elif [[ -t 0 ]]; then
    read -r -p "${label}: " value
  fi
  printf "%s" "$value"
}

ensure_signalwire_repo_token_file() {
  local dir
  dir="$(dirname "${SIGNALWIRE_REPO_TOKEN_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"

  if [[ -f "${SIGNALWIRE_REPO_TOKEN_FILE}" ]]; then
    TOKEN="$(tr -d '[:space:]' < "${SIGNALWIRE_REPO_TOKEN_FILE}")"
    ok "SignalWire repository token loaded from ${SIGNALWIRE_REPO_TOKEN_FILE}"
  else
    while true; do
      TOKEN="$(prompt_secret_value "Enter the SignalWire repository token/PAT")"
      if [[ -z "${TOKEN}" && "$DRY_RUN" == true ]]; then
        TOKEN="DRY_RUN_SIGNALWIRE_TOKEN"
      fi
      [[ -n "${TOKEN}" ]] || { err "SignalWire repository token is required to install FreeSWITCH."; return 1; }
      if [[ "${TOKEN}" =~ [[:space:]] ]]; then
        warn "SignalWire repository token cannot contain spaces. Paste the token exactly as provided."
        continue
      fi
      break
    done
    write_file "${SIGNALWIRE_REPO_TOKEN_FILE}" "${TOKEN}"
    ok "SignalWire repository token saved to ${SIGNALWIRE_REPO_TOKEN_FILE}"
  fi

  run "chown root:root '${SIGNALWIRE_REPO_TOKEN_FILE}'"
  run "chmod 0600 '${SIGNALWIRE_REPO_TOKEN_FILE}'"
}

add_repo_debian() {
  if [[ -n "${TOKEN}" ]]; then
    info "Configuring SignalWire repository through fsget..."
    run "apt-get update -y"
    run "apt-get install -y ca-certificates curl gnupg"
    run "curl -fsSL https://freeswitch.org/fsget | bash -s '${TOKEN}' release"
    if [[ -n "${FREESWITCH_REPO_SUITE:-}" ]]; then
      info "Forcando suite do repo: ${FREESWITCH_REPO_SUITE}"
      run "sed -i \"s/^Suites: .*/Suites: ${FREESWITCH_REPO_SUITE}/\" /etc/apt/sources.list.d/freeswitch.sources"
      run "apt-get update -y"
    fi
    return
  fi

  err "SignalWire repository token is missing. Run again and enter the token to save it at ${SIGNALWIRE_REPO_TOKEN_FILE}."
  err "Veja: https://developer.signalwire.com/freeswitch/FreeSWITCH-Explained/Installation/Linux/Debian_67240088"
  exit 2
}

detect_freeswitch_os() {
  if [[ ! -r /etc/os-release ]]; then
    err "Could not read /etc/os-release"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    debian)
      if [[ "${VERSION_ID:-}" =~ ^12(\..*)?$ ]]; then
        echo "debian"
        return 0
      fi
      ;;
  esac

  err "Unsupported operating system for FreeSWITCH. Supported: Debian 12."
  exit 2
}

generate_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid
    return 0
  fi
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  err "Could not generate a local UUID. Install uuid-runtime or use a kernel with /proc/sys/kernel/random/uuid."
  return 1
}

generate_secret_32() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
    return 0
  fi
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

ensure_control_secret() {
  local dir
  dir="$(dirname "${FS_CONTROL_SECRET_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"
  if [[ -f "${FS_CONTROL_SECRET_FILE}" ]]; then
    FS_CONTROL_SECRET="$(tr -d '[:space:]' < "${FS_CONTROL_SECRET_FILE}")"
  else
    FS_CONTROL_SECRET="$(generate_secret_32)"
    write_file "${FS_CONTROL_SECRET_FILE}" "${FS_CONTROL_SECRET}"
  fi
  run "chown root:root '${FS_CONTROL_SECRET_FILE}'"
  run "chmod 0600 '${FS_CONTROL_SECRET_FILE}'"
}

ensure_api_token_file() {
  local dir
  dir="$(dirname "${API_TOKEN_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"

  if [[ -f "${API_TOKEN_FILE}" ]]; then
    API_TOKEN="$(tr -d '[:space:]' < "${API_TOKEN_FILE}")"
    ok "PABX API token loaded from ${API_TOKEN_FILE}"
  else
    API_TOKEN="$(generate_secret_32)"
    write_file "${API_TOKEN_FILE}" "${API_TOKEN}"
    ok "PABX API token created at ${API_TOKEN_FILE}"
  fi

  if getent group freeswitch >/dev/null 2>&1; then
    run "chown root:freeswitch '${API_TOKEN_FILE}'"
  else
    run "chown root:root '${API_TOKEN_FILE}'"
  fi
  run "chmod 0640 '${API_TOKEN_FILE}'"
}

ensure_node_uuid_file() {
  local dir
  dir="$(dirname "${NODE_UUID_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"

  if [[ -f "${NODE_UUID_FILE}" ]]; then
    NODE_UUID="$(tr -d '[:space:]' < "${NODE_UUID_FILE}")"
    ok "Node UUID loaded from ${NODE_UUID_FILE}: ${NODE_UUID}"
  else
    NODE_UUID="${NODE_UUID:-$(generate_uuid)}"
    write_file "${NODE_UUID_FILE}" "${NODE_UUID}"
    ok "Node UUID created at ${NODE_UUID_FILE}: ${NODE_UUID}"
  fi

  local compact_node_uuid
  compact_node_uuid="${NODE_UUID//-/}"
  if [[ ! "${compact_node_uuid}" =~ ^[0-9A-Fa-f]{32}$ ]]; then
    err "Invalid Node UUID at ${NODE_UUID_FILE}: ${NODE_UUID}"
    return 1
  fi
  compact_node_uuid="$(echo "${compact_node_uuid}" | tr '[:upper:]' '[:lower:]')"
  NODE_UUID="${compact_node_uuid:0:8}-${compact_node_uuid:8:4}-${compact_node_uuid:12:4}-${compact_node_uuid:16:4}-${compact_node_uuid:20:12}"
  write_file "${NODE_UUID_FILE}" "${NODE_UUID}"

  if getent group freeswitch >/dev/null 2>&1; then
    run "chown root:freeswitch '${NODE_UUID_FILE}'"
  else
    run "chown root:root '${NODE_UUID_FILE}'"
  fi
  run "chmod 0640 '${NODE_UUID_FILE}'"
}

local_hostname() {
  hostname -f 2>/dev/null || hostname 2>/dev/null || echo ""
}

local_ipv4() {
  ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' ||
    hostname -I 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i !~ /:/) { print $i; exit }}'
}

api_base_host() {
  printf '%s\n' "${API_BASE}" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*$##; s#:.*$##'
}

resolve_api_base_ipv4s() {
  local host
  host="$(api_base_host)"
  [[ -n "${host}" ]] || return 1
  getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++'
}

ensure_control_allowed_ips() {
  local ip entries=() joined=""

  mapfile -t entries < <(resolve_api_base_ipv4s || true)
  if [[ "${#entries[@]}" -eq 0 ]]; then
    ip="$(local_ipv4)"
    [[ -n "${ip}" ]] && entries=("${ip}")
  fi

  for ip in "${entries[@]}"; do
    [[ -n "${ip}" ]] || continue
    [[ -n "${joined}" ]] && joined+=","
    joined+="${ip}/32"
  done

  FS_CONTROL_ALLOWED_IPS="${joined:-127.0.0.1/32}"
  info "ESL allowed IPs auto: ${FS_CONTROL_ALLOWED_IPS}"
}

local_ipv4_cidr() {
  local ip="$1"
  [[ -n "$ip" ]] || return 1
  ip -o -4 addr show scope global 2>/dev/null | awk -v ip="$ip" '{
    split($4, addr, "/");
    if (addr[1] == ip) {
      print $4;
      exit;
    }
  }'
}

is_global_ipv6() {
  local ip="${1%%/*}" lower
  [[ -n "$ip" && "$ip" == *:* ]] || return 1
  lower="$(echo "$ip" | tr '[:upper:]' '[:lower:]')"
  [[ "$lower" == fe80:* ]] && return 1
  [[ "$lower" == ::1 ]] && return 1
  [[ "$lower" == fc* || "$lower" == fd* ]] && return 1
  [[ "$lower" == ::ffff:* ]] && return 1
  return 0
}

local_ipv6_cidr() {
  ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | while read -r cidr; do
    if is_global_ipv6 "$cidr"; then
      printf '%s\n' "$cidr"
      return 0
    fi
  done
}

local_ipv6() {
  local cidr
  cidr="$(local_ipv6_cidr || true)"
  [[ -n "$cidr" ]] || return 1
  printf '%s\n' "${cidr%%/*}"
}

is_truthy() {
  case "${1,,}" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_broken_freeswitch_meta_packages() {
  local status
  status="$(dpkg-query -W -f='${db:Status-Abbrev}\n' ssmtp freeswitch-mod-voicemail freeswitch-meta-all 2>/dev/null || true)"
  if printf '%s\n' "$status" | grep -Eq '^[ih]?[UF]'; then
    warn "Cleaning broken optional packages from a previous attempt (ssmtp/voicemail/meta-all)."
    run "DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge freeswitch-meta-all freeswitch-mod-voicemail ssmtp || true"
  fi
  if dpkg-query -W -f='${db:Status-Abbrev}' freeswitch-mod-g729 >/dev/null 2>&1; then
    warn "Removing freeswitch-mod-g729 to keep only free G.729 through bcg729."
    run "DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge freeswitch-mod-g729 || true"
  fi
}

apt_install_optional() {
  local package="$1" description="${2:-$1}"
  if ! apt-cache show "${package}" >/dev/null 2>&1; then
    warn "Optional package ${package} not found. Skipping ${description}."
    return 1
  fi
  if run "apt-get install -y --no-install-recommends '${package}'"; then
    return 0
  fi
  warn "Optional package ${package} could not be installed. Skipping ${description}; the installer will continue."
  return 1
}

install_pkgs() {
  local os
  os="$(detect_freeswitch_os)"
  case "$os" in
    debian)
      add_repo_debian
      cleanup_broken_freeswitch_meta_packages
      if [[ "$DRY_RUN" != true ]] && ! apt-cache show freeswitch freeswitch-systemd freeswitch-conf-vanilla >/dev/null 2>&1; then
        err "FreeSWITCH packages were not found for the current suite."
        err "Recommended action: use Debian 12 or set FREESWITCH_REPO_SUITE=bookworm and run the installer again."
        exit 2
      fi
      run "apt-get install -y --no-install-recommends \
        freeswitch freeswitch-systemd freeswitch-conf-vanilla \
        freeswitch-mod-sofia freeswitch-mod-dptools freeswitch-mod-dialplan-xml freeswitch-mod-xml-curl \
        freeswitch-mod-curl freeswitch-mod-commands freeswitch-mod-event-socket \
        freeswitch-mod-console freeswitch-mod-logfile freeswitch-mod-db \
        freeswitch-mod-hash freeswitch-mod-lua freeswitch-mod-conference \
        freeswitch-mod-opus freeswitch-mod-av freeswitch-mod-sndfile freeswitch-mod-native-file \
        freeswitch-mod-local-stream freeswitch-mod-tone-stream freeswitch-mod-say-en \
        freeswitch-mod-json-cdr freeswitch-mod-mariadb \
        build-essential git cmake pkg-config \
        unixodbc odbc-mariadb libbcg729-0 libbcg729-dev \
        sngrep tcpdump ngrep dnsutils traceroute mtr-tiny netcat-openbsd jq"
      if apt_install_optional "libfreeswitch-dev" "FreeSWITCH headers for optional mod_bcg729 build"; then
        :
      elif apt_install_optional "freeswitch-dev" "FreeSWITCH headers for optional mod_bcg729 build"; then
        :
      else
        warn "FreeSWITCH headers package not found (libfreeswitch-dev/freeswitch-dev). mod_bcg729 compilation may fail without /usr/include/freeswitch/switch.h."
      fi
      if ! apt_install_optional "freeswitch-mod-bcg729" "prebuilt FreeSWITCH bcg729 module"; then
        warn "Package freeswitch-mod-bcg729 was not found in the configured repositories. Official libbcg729 was installed; mod_bcg729 will be enabled only if the module exists on the system."
      fi
      ;;
    *)
      err "Unsupported operating system. Supported: Debian 12."
      exit 2
      ;;
  esac
}

ensure_module_loaded() {
  local module="$1"
  local file="/etc/freeswitch/autoload_configs/modules.conf.xml"
  if [[ ! -f "$file" ]]; then
    warn "modules.conf.xml not found at ${file} (FreeSWITCH must be installed)."
    return
  fi
  backup_once "$file"
  if grep -q "^[[:space:]]*<load module=\"${module}\"/>" "$file"; then
    ok "Module ${module} already enabled."
    return
  fi
  if grep -q "<!--[[:space:]]*<load module=\"${module}\"/>[[:space:]]*-->" "$file"; then
    info "Uncommenting module ${module} em ${file}"
    run "sed -i 's|<!--[[:space:]]*<load module=\"${module}\"/>[[:space:]]*-->|<load module=\"${module}\"/>|' ${file}"
    return
  fi
  info "Enabling module ${module} em ${file}"
  run "sed -i '/<\/modules>/i\\  <load module=\"${module}\"\\/>' ${file}"
}

disable_module_loaded() {
  local module="$1"
  local file="/etc/freeswitch/autoload_configs/modules.conf.xml"
  if [[ ! -f "$file" ]]; then
    return
  fi
  backup_once "$file"
  if grep -q "^[[:space:]]*<load module=\"${module}\"/>" "$file"; then
    info "Disabling module ${module} em ${file}"
    run "sed -i 's|^[[:space:]]*<load module=\"${module}\"/>|  <!-- <load module=\"${module}\"/> -->|' ${file}"
  fi
}

module_file_exists() {
  local module="$1"
  find /usr/lib /usr/lib64 -path "*/freeswitch/mod/${module}.so" -print -quit 2>/dev/null | grep -q .
}

write_modules_config() {
  local path="/etc/freeswitch/autoload_configs/modules.conf.xml"
  local module modules_xml=""
  local modules=(
    mod_logfile
    mod_console
    mod_xml_curl
    mod_event_socket
    mod_sofia
    mod_commands
    mod_conference
    mod_db
    mod_dptools
    mod_hash
    mod_dialplan_xml
    mod_opus
    mod_av
    mod_sndfile
    mod_native_file
    mod_local_stream
    mod_tone_stream
    mod_say_en
    mod_lua
    mod_curl
    mod_json_cdr
    mod_mariadb
    mod_bcg729
  )

  if [[ ! -d "$(dirname "$path")" ]]; then
    run "mkdir -p '$(dirname "$path")'"
  fi

  backup_once "$path"
  for module in "${modules[@]}"; do
    if module_file_exists "$module"; then
      modules_xml+="    <load module=\"${module}\"/>
"
    else
      warn "Module ${module}.so not found; it will not be loaded in modules.conf.xml."
    fi
  done

  write_file "$path" "\
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<configuration name=\"modules.conf\" description=\"Modules\">
  <modules>
${modules_xml}  </modules>
</configuration>
"
}

freeswitch_module_dir() {
  local dir
  dir="$(find /usr/lib /usr/lib64 -type d -path "*/freeswitch/mod" -print -quit 2>/dev/null || true)"
  if [[ -n "$dir" ]]; then
    printf '%s\n' "$dir"
    return 0
  fi
  printf '/usr/lib/freeswitch/mod\n'
}

freeswitch_include_dir() {
  local dir
  for dir in /usr/include/freeswitch /usr/local/freeswitch/include; do
    if [[ -f "${dir}/switch.h" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

build_mod_bcg729() {
  if module_file_exists "mod_bcg729"; then
    ok "mod_bcg729.so ja existe no sistema."
    return 0
  fi

  local include_dir module_dir
  if ! include_dir="$(freeswitch_include_dir)"; then
    warn "FreeSWITCH headers not found; skipping mod_bcg729 build."
    return 1
  fi
  if [[ ! -f /usr/include/bcg729/encoder.h || ! -f /usr/include/bcg729/decoder.h ]]; then
    warn "bcg729 headers not found in /usr/include/bcg729; skipping mod_bcg729 build."
    return 1
  fi

  module_dir="$(freeswitch_module_dir)"
  run "rm -rf '${BCG729_BUILD_DIR}'"
  if [[ -f "${BCG729_BUNDLED_SOURCE_DIR}/mod_bcg729.c" ]]; then
    info "Compilando mod_bcg729 gratuito a partir do fonte local ${BCG729_BUNDLED_SOURCE_DIR}..."
    run "cp -a '${BCG729_BUNDLED_SOURCE_DIR}' '${BCG729_BUILD_DIR}'"
  else
    info "Local mod_bcg729 source not found; downloading ${BCG729_SOURCE_URL} (${BCG729_SOURCE_REF})..."
    run "git clone --depth 1 '${BCG729_SOURCE_URL}' '${BCG729_BUILD_DIR}'"
    run "cd '${BCG729_BUILD_DIR}' && git fetch --depth 1 origin '${BCG729_SOURCE_REF}' && git checkout '${BCG729_SOURCE_REF}'"
  fi
  run "cd '${BCG729_BUILD_DIR}' && cc -fPIC -O2 -fomit-frame-pointer -fno-exceptions -Wall -std=c99 -I'${include_dir}' -I/usr/include -shared -Xlinker -x -o mod_bcg729.so mod_bcg729.c -lbcg729 -lm"
  run "install -m 0755 '${BCG729_BUILD_DIR}/mod_bcg729.so' '${module_dir}/mod_bcg729.so'"
  ok "mod_bcg729.so installed at ${module_dir}/mod_bcg729.so"
}

backup_once() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    return
  fi

  local backup="${path}.bkp"
  if [[ -e "$backup" ]]; then
    ok "Backup already exists: ${backup}"
    return
  fi

  if [[ -d "$path" ]]; then
    run "cp -a '${path}' '${backup}'"
  else
    run "cp -a '${path}' '${backup}'"
  fi
  ok "Backup created: ${backup}"
}

xml_escape_attr() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s' "${value}"
}

write_xml_curl() {
  local path="/etc/freeswitch/autoload_configs/xml_curl.conf.xml"
  local dir
  dir="$(dirname "$path")"
  [[ -d "$dir" ]] || run "mkdir -p ${dir}"
  [[ -d /var/log/freeswitch/xml_curl ]] || run "mkdir -p /var/log/freeswitch/xml_curl"
  backup_once "$path"

  local api_token_xml
  api_token_xml="$(xml_escape_attr "${API_TOKEN}")"

  write_file "$path" "\
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<configuration name=\"xml_curl.conf\" description=\"XML Curl PABX\">
  <bindings>
    <binding name=\"pabx-directory\">
      <!-- API endpoint: /api/v1/pabx/freeswitch -->
      <param name=\"gateway-url\" value=\"${API_BASE}/api/v1/pabx/freeswitch?node_uuid=${NODE_UUID}\" bindings=\"directory\"/>
      <param name=\"method\" value=\"POST\"/>
      <param name=\"enable-cacert-check\" value=\"false\"/>
      <param name=\"timeout\" value=\"10\"/>
      <param name=\"retry\" value=\"1\"/>
      <param name=\"log-dir\" value=\"/var/log/freeswitch/xml_curl\"/>
      <param name=\"gateway-credentials\" value=\"mnscloud:${api_token_xml}\"/>
      <param name=\"auth-scheme\" value=\"basic\"/>
    </binding>
    <binding name=\"pabx-dialplan\">
      <!-- API endpoint: /api/v1/pabx/freeswitch -->
      <param name=\"gateway-url\" value=\"${API_BASE}/api/v1/pabx/freeswitch?node_uuid=${NODE_UUID}\" bindings=\"dialplan\"/>
      <param name=\"method\" value=\"POST\"/>
      <param name=\"enable-cacert-check\" value=\"false\"/>
      <param name=\"timeout\" value=\"10\"/>
      <param name=\"retry\" value=\"1\"/>
      <param name=\"log-dir\" value=\"/var/log/freeswitch/xml_curl\"/>
      <param name=\"gateway-credentials\" value=\"mnscloud:${api_token_xml}\"/>
      <param name=\"auth-scheme\" value=\"basic\"/>
    </binding>
    <binding name=\"pabx-configuration\">
      <!-- API endpoint: /api/v1/pabx/freeswitch -->
      <param name=\"gateway-url\" value=\"${API_BASE}/api/v1/pabx/freeswitch?node_uuid=${NODE_UUID}\" bindings=\"configuration\"/>
      <param name=\"method\" value=\"POST\"/>
      <param name=\"enable-cacert-check\" value=\"false\"/>
      <param name=\"timeout\" value=\"10\"/>
      <param name=\"retry\" value=\"1\"/>
      <param name=\"log-dir\" value=\"/var/log/freeswitch/xml_curl\"/>
      <param name=\"gateway-credentials\" value=\"mnscloud:${api_token_xml}\"/>
      <param name=\"auth-scheme\" value=\"basic\"/>
    </binding>
  </bindings>
</configuration>
"
}

write_json_cdr_config() {
  local path="/etc/freeswitch/autoload_configs/json_cdr.conf.xml"
  local dir
  dir="$(dirname "$path")"
  [[ -d "$dir" ]] || run "mkdir -p ${dir}"
  [[ -d /var/log/freeswitch/json_cdr ]] || run "mkdir -p /var/log/freeswitch/json_cdr"
  [[ -d /var/log/freeswitch/json_cdr/errors ]] || run "mkdir -p /var/log/freeswitch/json_cdr/errors"
  backup_once "$path"

  local api_token_xml
  api_token_xml="$(xml_escape_attr "${API_TOKEN}")"

  write_file "$path" "\
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<configuration name=\"json_cdr.conf\" description=\"JSON CDR\">
  <settings>
    <param name=\"log-b-leg\" value=\"false\"/>
    <param name=\"prefix-a-leg\" value=\"false\"/>
    <param name=\"encode-values\" value=\"false\"/>
    <param name=\"log-http-and-disk\" value=\"false\"/>
    <param name=\"log-dir\" value=\"/var/log/freeswitch/json_cdr\"/>
    <param name=\"err-log-dir\" value=\"/var/log/freeswitch/json_cdr/errors\"/>
    <param name=\"url\" value=\"${API_BASE}/api/v1/voip/pabx/cdr/freeswitch/internal/${NODE_UUID}\"/>
    <param name=\"auth-scheme\" value=\"basic\"/>
    <param name=\"cred\" value=\"mnscloud:${api_token_xml}\"/>
    <param name=\"encode\" value=\"false\"/>
    <param name=\"retries\" value=\"2\"/>
    <param name=\"delay\" value=\"5000\"/>
    <param name=\"disable-100-continue\" value=\"true\"/>
    <param name=\"enable-ssl-verifyhost\" value=\"false\"/>
    <param name=\"enable-cacert-check\" value=\"false\"/>
  </settings>
</configuration>
"
}

write_event_socket_config() {
  local path="/etc/freeswitch/autoload_configs/event_socket.conf.xml"
  local dir
  dir="$(dirname "$path")"
  [[ -d "$dir" ]] || run "mkdir -p ${dir}"
  backup_once "$path"
  write_file "$path" "\
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<configuration name=\"event_socket.conf\" description=\"Socket Client\">
  <settings>
    <param name=\"listen-ip\" value=\"${FS_CONTROL_LISTEN_IP}\"/>
    <param name=\"listen-port\" value=\"${FS_CONTROL_PORT}\"/>
    <param name=\"password\" value=\"${FS_CONTROL_SECRET}\"/>
    <param name=\"apply-inbound-acl\" value=\"mnscloud-control\"/>
  </settings>
</configuration>"
}

write_fs_cli_config() {
  local path="/etc/fs_cli.conf"
  backup_once "$path"
  write_file "$path" "\
[default]
host => 127.0.0.1
port => ${FS_CONTROL_PORT}
password => ${FS_CONTROL_SECRET}
loglevel => notice
"
  run "chown root:root '${path}'"
  run "chmod 0600 '${path}'"
}

write_acl_config() {
  local path="/etc/freeswitch/autoload_configs/acl.conf.xml"
  local allowed="${FS_CONTROL_ALLOWED_IPS:-127.0.0.1/32}"
  local nodes="      <node type=\"allow\" cidr=\"127.0.0.1/32\"/>
"
  local entry
  IFS=',' read -ra entries <<< "${allowed}"
  for entry in "${entries[@]}"; do
    entry="$(echo "$entry" | xargs)"
    [[ -n "$entry" ]] || continue
    [[ "$entry" == "127.0.0.1/32" ]] && continue
    nodes+="      <node type=\"allow\" cidr=\"${entry}\"/>
"
  done
  backup_once "$path"
  write_file "$path" "\
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<configuration name=\"acl.conf\" description=\"Network Lists\">
  <network-lists>
    <list name=\"localnet.auto\" default=\"deny\">
      <node type=\"allow\" cidr=\"127.0.0.0/8\"/>
      <node type=\"allow\" cidr=\"10.0.0.0/8\"/>
      <node type=\"allow\" cidr=\"172.16.0.0/12\"/>
      <node type=\"allow\" cidr=\"192.168.0.0/16\"/>
      <node type=\"allow\" cidr=\"::1/128\"/>
      <node type=\"allow\" cidr=\"fc00::/7\"/>
      <node type=\"allow\" cidr=\"fe80::/10\"/>
    </list>
    <list name=\"mnscloud-control\" default=\"deny\">
${nodes}    </list>
  </network-lists>
</configuration>"
}

write_sofia_config() {
  local path="/etc/freeswitch/autoload_configs/sofia.conf.xml"
  local dir
  dir="$(dirname "$path")"
  [[ -d "$dir" ]] || run "mkdir -p ${dir}"
  backup_once "$path"

  write_file "$path" "\
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<configuration name=\"sofia.conf\" description=\"Sofia SIP Endpoint\">
  <global_settings>
    <param name=\"log-level\" value=\"0\"/>
    <param name=\"debug-presence\" value=\"0\"/>
  </global_settings>
  <profiles>
    <X-PRE-PROCESS cmd=\"include\" data=\"../sip_profiles/*.xml\"/>
  </profiles>
</configuration>
"
}

write_internal_profile() {
  local path="/etc/freeswitch/sip_profiles/internal.xml"
  local dir
  local local_ip ext_sip_ip ext_rtp_ip presence_hosts
  dir="$(dirname "$path")"
  local_ip="${FS_LOCAL_IP:-}"
  [[ -n "$local_ip" ]] || local_ip='$${local_ip_v4}'
  ext_sip_ip="$(resolve_external_sip_ip)"
  ext_rtp_ip="$(resolve_external_rtp_ip)"
  presence_hosts="${ext_sip_ip}"
  [[ "$presence_hosts" != "auto-nat" ]] || presence_hosts="${local_ip}"
  [[ -d "$dir" ]] || run "mkdir -p ${dir}"
  backup_once "$path"

  write_file "$path" "\
<profile name=\"internal\">
  <settings>
    <param name=\"debug\" value=\"0\"/>
    <param name=\"user-agent-string\" value=\"MNSCloud Freeswitch\"/>
    <param name=\"sip-trace\" value=\"no\"/>
    <param name=\"sip-capture\" value=\"no\"/>
    <param name=\"context\" value=\"public\"/>
    <param name=\"dialplan\" value=\"XML\"/>
    <param name=\"sip-port\" value=\"5060\"/>
    <param name=\"sip-ip\" value=\"${local_ip}\"/>
    <param name=\"rtp-ip\" value=\"${local_ip}\"/>
    <param name=\"ext-sip-ip\" value=\"${ext_sip_ip}\"/>
    <param name=\"ext-rtp-ip\" value=\"${ext_rtp_ip}\"/>
    <param name=\"challenge-realm\" value=\"auto_from\"/>
    <param name=\"auth-calls\" value=\"true\"/>
    <param name=\"auth-subscriptions\" value=\"true\"/>
    <param name=\"auth-all-packets\" value=\"false\"/>
    <param name=\"inbound-reg-force-matching-username\" value=\"true\"/>
    <param name=\"accept-blind-reg\" value=\"false\"/>
    <param name=\"accept-blind-auth\" value=\"false\"/>
    <param name=\"local-network-acl\" value=\"localnet.auto\"/>
    <param name=\"apply-nat-acl\" value=\"nat.auto\"/>
    <param name=\"aggressive-nat-detection\" value=\"true\"/>
    <param name=\"NDLB-force-rport\" value=\"true\"/>
    <param name=\"NDLB-connectile-dysfunction\" value=\"true\"/>
    <param name=\"NDLB-received-in-nat-reg-contact\" value=\"true\"/>
    <param name=\"rewrite-contact\" value=\"true\"/>
    <param name=\"manage-presence\" value=\"true\"/>
    <param name=\"presence-hosts\" value=\"${presence_hosts}\"/>
    <param name=\"inbound-codec-prefs\" value=\"OPUS,PCMU,PCMA,G729,G722,H264\"/>
    <param name=\"outbound-codec-prefs\" value=\"OPUS,PCMU,PCMA,G729,G722,H264\"/>
    <param name=\"inbound-codec-negotiation\" value=\"generous\"/>
    <param name=\"rtp-timer-name\" value=\"soft\"/>
    <param name=\"rfc2833-pt\" value=\"101\"/>
    <param name=\"dtmf-duration\" value=\"2000\"/>
    <param name=\"hold-music\" value=\"local_stream://moh\"/>
    <param name=\"record-path\" value=\"/var/lib/freeswitch/recordings\"/>
    <param name=\"record-template\" value=\"\${caller_id_number}.\${target_domain}.\${strftime(%Y-%m-%d-%H-%M-%S)}.wav\"/>
    <param name=\"tls\" value=\"false\"/>
    <param name=\"ws-binding\" value=\":5066\"/>
    <param name=\"wss-binding\" value=\":7443\"/>
  </settings>
</profile>
"
}

disable_default_directory() {
  local directory="/etc/freeswitch/directory"
  [[ -d "$directory" ]] || return 0

  backup_once "$directory"

  run "find '${directory}' -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
  write_file "${directory}/mnscloud-empty.xml" "\
<include>
  <!-- Static demo users are disabled. Directory users are served by XML Curl. -->
</include>
"
}

write_odbc_ini() {
  if [[ -z "${FS_DB_HOST}" || -z "${FS_DB_NAME}" || -z "${FS_DB_USER}" || -z "${FS_DB_PASS}" ]]; then
    warn "DB variables for ODBC are not defined (FS_DB_HOST/FS_DB_NAME/FS_DB_USER/FS_DB_PASS). Skipping DSN creation."
    return
  fi
  backup_once "/etc/odbc.ini"
  write_file "/etc/odbc.ini" "\
[mnscloud_freeswitch]
Description=FreeSWITCH MariaDB
Driver=MariaDB Unicode
Server=${FS_DB_HOST}
Port=${FS_DB_PORT}
Database=${FS_DB_NAME}
User=${FS_DB_USER}
Password=${FS_DB_PASS}
Option=3
"
}

validate_media_codecs() {
  run "fs_cli -H 127.0.0.1 -P '${FS_CONTROL_PORT}' -p '${FS_CONTROL_SECRET}' -x 'show codecs' | grep -Ei 'G729|H264' || true"
  run "fs_cli -H 127.0.0.1 -P '${FS_CONTROL_PORT}' -p '${FS_CONTROL_SECRET}' -x 'module_exists mod_bcg729' || true"
}

wait_for_freeswitch_cli() {
  local attempt
  if $DRY_RUN; then
    log DRY "fs_cli -x status"
    return 0
  fi

  for attempt in $(seq 1 30); do
    if fs_cli -H 127.0.0.1 -P "${FS_CONTROL_PORT}" -p "${FS_CONTROL_SECRET}" -x 'status' >/dev/null 2>&1; then
      ok "FreeSWITCH is accepting fs_cli connections."
      return 0
    fi
    sleep 1
  done

  warn "FreeSWITCH did not accept fs_cli after startup; collecting diagnostics."
  run "systemctl status freeswitch --no-pager || true"
  run "journalctl -u freeswitch -n 120 --no-pager || true"
  err "FreeSWITCH did not accept fs_cli connection after startup. Check the error above before continuing."
  return 1
}

is_public_ipv4() {
  local ip="$1" first second third fourth octet
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r first second third fourth <<<"$ip"
  for octet in "$first" "$second" "$third" "$fourth"; do
    [[ "$octet" =~ ^[0-9]+$ && "$octet" -ge 0 && "$octet" -le 255 ]] || return 1
  done
  [[ "$first" -eq 10 ]] && return 1
  [[ "$first" -eq 127 ]] && return 1
  [[ "$first" -eq 169 && "$second" -eq 254 ]] && return 1
  [[ "$first" -eq 172 && "$second" -ge 16 && "$second" -le 31 ]] && return 1
  [[ "$first" -eq 192 && "$second" -eq 168 ]] && return 1
  [[ "$first" -eq 100 && "$second" -ge 64 && "$second" -le 127 ]] && return 1
  [[ "$first" -eq 0 ]] && return 1
  return 0
}

discover_public_ip() {
  local ip service
  for service in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"; do
    ip="$(curl -fsS --max-time 4 "$service" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_public_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

ensure_curl_for_validation() {
  command -v curl >/dev/null 2>&1 && return 0

  if $DRY_RUN; then
    log DRY "apt-get update -y"
    log DRY "apt-get install -y --no-install-recommends ca-certificates curl"
    return 0
  fi

  warn "curl not found; installing the minimum dependency required to validate the Node UUID via API."
  run "apt-get update -y"
  run "apt-get install -y --no-install-recommends ca-certificates curl"
}

resolve_external_media_ip() {
  local ip
  if [[ -n "${API_VALIDATED_PUBLIC_IP}" ]]; then
    log_raw "INFO" "Using public IP validated by the API: ${API_VALIDATED_PUBLIC_IP}"
    printf '%s\n' "${API_VALIDATED_PUBLIC_IP}"
    return 0
  fi
  if is_truthy "${FS_AUTO_DISCOVER_PUBLIC_IP:-1}"; then
    if ip="$(discover_public_ip 2>/dev/null || true)" && [[ -n "$ip" ]]; then
      log_raw "INFO" "Public IP detected automatically: ${ip}"
      printf '%s\n' "$ip"
      return 0
    fi
  fi
  printf 'auto-nat\n'
}

resolve_external_sip_ip() {
  if [[ -n "${FS_EXT_SIP_IP}" && "${FS_EXT_SIP_IP}" != "auto-nat" ]]; then
    printf '%s\n' "${FS_EXT_SIP_IP}"
    return 0
  fi
  resolve_external_media_ip
}

resolve_external_rtp_ip() {
  if [[ -n "${FS_EXT_RTP_IP}" && "${FS_EXT_RTP_IP}" != "auto-nat" ]]; then
    printf '%s\n' "${FS_EXT_RTP_IP}"
    return 0
  fi
  resolve_external_media_ip
}

json_field() {
  local field="$1" file="$2"
  grep -o "\"${field}\":\"[^\"]*\"" "$file" | head -n1 | cut -d'"' -f4 || true
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/}"
  printf '%s' "$value"
}

heartbeat() {
  local payload response_file http_code server_uuid public_ip private_ip control_host private_cidr private_ipv6 private_ipv6_cidr hostname_value version
  if $DRY_RUN; then
    log DRY "POST ${API_BASE}/api/v1/pabx/freeswitch/heartbeat?node_uuid=${NODE_UUID}"
    return 0
  fi
  hostname_value="$(hostname -f 2>/dev/null || hostname)"
  private_ip="$(local_ipv4)"
  private_cidr="$(local_ipv4_cidr "${private_ip}" || true)"
  private_ipv6="$(local_ipv6 || true)"
  private_ipv6_cidr="$(local_ipv6_cidr || true)"
  public_ip="$(discover_public_ip || true)"
  control_host="${public_ip:-${private_ip}}"
  version="$(freeswitch -version 2>/dev/null | head -n1 | tr -d '\r' || true)"
  payload="{\"hostname\":\"$(json_escape "${hostname_value}")\",\"privateIPv4\":\"$(json_escape "${private_ip}")\",\"version\":\"$(json_escape "${version}")\",\"baseUrl\":\"$(json_escape "${API_BASE}")\""
  if [[ -n "${public_ip}" ]]; then
    payload+=",\"publicIPv4\":\"$(json_escape "${public_ip}")\""
  fi
  if [[ -n "${private_cidr}" ]]; then
    payload+=",\"localNet\":\"$(json_escape "${private_cidr}")\""
  fi
  if [[ -n "${private_ipv6}" ]]; then
    payload+=",\"privateIPv6\":\"$(json_escape "${private_ipv6}")\",\"publicIPv6\":\"$(json_escape "${private_ipv6}")\""
  fi
  if [[ -n "${private_ipv6_cidr}" ]]; then
    payload+=",\"localNetIPv6\":\"$(json_escape "${private_ipv6_cidr}")\""
  fi
  payload+=",\"controlHost\":\"$(json_escape "${control_host}")\",\"controlPort\":${FS_CONTROL_PORT},\"controlSecret\":\"$(json_escape "${FS_CONTROL_SECRET}")\",\"controlAllowedIps\":\"$(json_escape "${FS_CONTROL_ALLOWED_IPS}")\""
  payload+="}"
  response_file="$(mktemp)"
  set +e
  http_code="$(curl -sS -o "${response_file}" -w "%{http_code}" -X POST "${API_BASE}/api/v1/pabx/freeswitch/heartbeat?node_uuid=${NODE_UUID}" -H "Content-Type: application/json" -H "Authorization: Bearer ${API_TOKEN}" --data "${payload}" 2>>"${LOG_FILE}")"
  set -e
  if [[ "${http_code}" == "200" ]]; then
    server_uuid="$(json_field "serverUUID" "${response_file}")"
    API_VALIDATED_PUBLIC_IP="$(json_field "publicIPv4" "${response_file}")"
    if ! is_public_ipv4 "${API_VALIDATED_PUBLIC_IP}"; then
      API_VALIDATED_PUBLIC_IP=""
    fi
    if [[ -n "${server_uuid}" ]]; then
      ok "FreeSWITCH server registered/linked in the API. serverUUID: ${server_uuid}"
    else
      ok "Heartbeat FreeSWITCH aceito pela API."
    fi
    [[ -n "${API_VALIDATED_PUBLIC_IP}" ]] && ok "Public IP validated by the API: ${API_VALIDATED_PUBLIC_IP}"
    rm -f "${response_file}"
    return 0
  else
    warn "FreeSWITCH heartbeat returned HTTP ${http_code:-000}. Check that the API is updated/restarted and that the FreeSWITCH server is registered. Response: $(tr '\n' ' ' < "${response_file}" | head -c 200)"
    if [[ "${http_code}" == "401" ]]; then
      warn "HTTP 401 means the local api.token does not match the server token hash, or the API was not updated/restarted with first-heartbeat token initialization."
    elif [[ "${http_code}" == "404" ]]; then
      warn "HTTP 404 means the Node UUID is not saved on an active FreeSWITCH VoipPabxServer record, or the record engine is different."
    fi
  fi
  rm -f "${response_file}"
  return 1
}

wait_for_node_registration() {
  info "Node UUID for this FreeSWITCH host: ${NODE_UUID}"
  info "Register this exact Node UUID in the correct VoipPabxServer FreeSWITCH record before continuing."

  if ! [[ -r /dev/tty && -w /dev/tty ]]; then
    warn "Interactive terminal is unavailable at /dev/tty; skipping Node UUID registration wait."
    return 1
  fi

  ensure_curl_for_validation

  local answer
  while true; do
    printf "%s\n" "After registering the Node UUID in the platform, type 'validate' to test it, or type 'skip' to continue without validation: " >/dev/tty
    IFS= read -r answer </dev/tty
    if [[ "${answer,,}" == "skip" ]]; then
      warn "Node UUID registration was not validated. The installer will try HTTPS discovery and then auto-nat."
      return 1
    fi
    if [[ "${answer,,}" != "validate" ]]; then
      warn "Empty or invalid answer. Register the Node UUID first, then type 'validate'."
      continue
    fi
    if heartbeat; then
      return 0
    fi
    printf "%s\n" "Validation failed. Confirm the Node UUID was saved in the correct FreeSWITCH server record and try again." >/dev/tty
  done
}

main() {
  banner "freeswitch      PABX - FreeSWITCH 1.11.x (official repository)" "Debian 12"
  require_root
  local app_security_script="${MNSCLOUD_MONOREPO_ROOT:-${PROJECT_ROOT}}/scripts/application-security.sh"
  [[ -f "${app_security_script}" ]] && run_script "${app_security_script}"
  ensure_local_hostname_hosts
  load_env_file
  ensure_api_base_file
  ensure_node_uuid_file
  ensure_api_token_file
  ensure_control_secret
  ensure_control_allowed_ips

  if [[ -z "${NODE_UUID}" ]]; then
    err "Could not resolve the local node UUID."
    exit 2
  fi

  info "Node UUID: ${NODE_UUID}"
  info "API base:  ${API_BASE}"
  wait_for_node_registration || true
  ensure_signalwire_repo_token_file

  install_pkgs

  ensure_module_loaded "mod_xml_curl"
  ensure_module_loaded "mod_lua"
  ensure_module_loaded "mod_sofia"
  ensure_module_loaded "mod_event_socket"
  ensure_module_loaded "mod_dialplan_xml"
  ensure_module_loaded "mod_conference"
  ensure_module_loaded "mod_dptools"
  ensure_module_loaded "mod_commands"
  ensure_module_loaded "mod_sndfile"
  ensure_module_loaded "mod_native_file"
  disable_module_loaded "mod_com_g729"
  disable_module_loaded "mod_g729"
  build_mod_bcg729 || true
  if module_file_exists "mod_bcg729"; then
    ensure_module_loaded "mod_bcg729"
  else
    warn "mod_bcg729.so not found. Kept without the commercial module; install the official freeswitch-mod-bcg729 package when available in the configured repository."
  fi
  write_modules_config

  write_xml_curl
  write_json_cdr_config
  write_acl_config
  write_event_socket_config
  write_fs_cli_config
  write_sofia_config
  write_internal_profile
  disable_default_directory
  write_odbc_ini

  info "Enabling freeswitch service..."
  run "systemctl enable --now freeswitch"
  wait_for_freeswitch_cli
  validate_media_codecs
  heartbeat || true

  ok "FreeSWITCH installed and configured to consume XML through ${API_BASE}/api/v1/pabx/freeswitch"
  ok "Node UUID persisted at ${NODE_UUID_FILE}"
  ok "Check /etc/freeswitch/autoload_configs/xml_curl.conf.xml and customize endpoints/headers if necessary."
}

main
