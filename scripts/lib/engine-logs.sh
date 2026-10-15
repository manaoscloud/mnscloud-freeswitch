#!/usr/bin/env bash
# Engine log settings (server Logs tab): installs the per-minute refresher of this engine.
# The timer runs a fixed root-owned script; API responses never choose commands or paths.
ENGINE_LOGS_DIR="/usr/local/lib/mnscloud/engine-logs"

install_engine_logs_timer() {
  local engine="$1" source_dir="$2"
  local unit="mnscloud-${engine}-logs"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    info "[dry-run] Would install the ${engine} log settings timer (${unit}.timer)."
    return 0
  fi
  install -d -m 0755 "${ENGINE_LOGS_DIR}"
  install -m 0644 "${source_dir}/mnscloud_engine_logs.py" "${ENGINE_LOGS_DIR}/mnscloud_engine_logs.py"
  install -m 0755 "${source_dir}/${engine}-logs.py" "${ENGINE_LOGS_DIR}/${engine}-logs.py"
  cat > "/etc/systemd/system/${unit}.service" <<EOF
[Unit]
Description=Apply MNSCloud ${engine} log settings and rotate its logs
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 -I ${ENGINE_LOGS_DIR}/${engine}-logs.py
UMask=0027
TimeoutStartSec=120
EOF
  cat > "/etc/systemd/system/${unit}.timer" <<EOF
[Unit]
Description=Refresh ${engine} log settings every minute
[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
RandomizedDelaySec=10s
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${unit}.timer"
  # First run now, so a full log is rotated right after install/update; failures retry each minute.
  systemctl start "${unit}.service" || warn "First ${engine} log settings refresh failed; the timer retries every minute (journalctl -u ${unit})."
  ok "${engine} log settings timer installed (${unit}.timer)."
}
