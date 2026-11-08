#!/usr/bin/env bash
# install-ntfy-ssh-alerts.sh
# Reusable installer for ntfy SSH alerts on Linux servers.
#
# Deploys an auth-log watcher (or optional PAM hook) that sends ntfy
# notifications for SSH login, logout, and failed authentication events.
#
# Usage:
#   sudo ./install-ntfy-ssh-alerts.sh
#   sudo NTFY_ENDPOINT=https://ntfy.example.com NTFY_TOPIC=ssh-alerts ./install-ntfy-ssh-alerts.sh -y
#   sudo ./install-ntfy-ssh-alerts.sh --uninstall
#
# Environment variables (all optional; missing values are prompted):
#   NTFY_ENDPOINT      - ntfy server URL, e.g. https://ntfy.example.com
#   NTFY_TOPIC         - ntfy topic to publish to
#   NTFY_ACCESS_TOKEN  - ntfy access token (Bearer auth)
#   NTFY_LOGIN_PRIORITY    - default 3
#   NTFY_LOGOUT_PRIORITY   - default 2
#   NTFY_FAILED_PRIORITY   - default 4
#
# The installer defaults to the auth-log watcher because it does not modify
# PAM/SSH configuration. Use --pam to install the PAM hook instead (advanced).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/ntfy-ssh"
CONFIG_FILE="${CONFIG_DIR}/ntfy-ssh.conf"
BIN_DIR="/usr/local/bin"
WATCHER_SCRIPT="${BIN_DIR}/ntfy-ssh-authlog.sh"
PAM_SCRIPT="${BIN_DIR}/ntfy-ssh-notify.sh"
SERVICE_FILE="/etc/systemd/system/ntfy-ssh-authlog.service"
SERVICE_NAME="ntfy-ssh-authlog"
PAM_SSHD="/etc/pam.d/sshd"

UNATTENDED=false
UNINSTALL=false
USE_PAM=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Install ntfy SSH alerts on this Linux server.

Options:
  -y, --yes          Non-interactive install; use env vars for config
  --pam              Install the PAM hook instead of the auth-log watcher
  --uninstall        Remove all installed files, config, and systemd units
  -h, --help         Show this help message

Examples:
  sudo $0
  sudo NTFY_ENDPOINT=https://ntfy.example.com NTFY_TOPIC=alerts $0 -y
  sudo $0 --uninstall
EOF
}

log() {
  echo "[ntfy-ssh-install] $*"
}

error() {
  echo "[ntfy-ssh-install] ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error "This script must be run as root or with sudo."
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "Required command not found: ${cmd}"
  fi
}

# Parse command-line arguments.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      UNATTENDED=true
      shift
      ;;
    --pam)
      USE_PAM=true
      shift
      ;;
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown argument: $1"
      ;;
  esac
done

# --- Uninstall mode ---------------------------------------------------------
if [[ "$UNINSTALL" == true ]]; then
  require_root
  log "Uninstalling ntfy SSH alerts..."

  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl stop "$SERVICE_NAME" || true
  fi
  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl disable "$SERVICE_NAME" || true
  fi

  rm -f "$SERVICE_FILE" "$WATCHER_SCRIPT" "$PAM_SCRIPT"

  if [[ -f "$CONFIG_FILE" ]]; then
    if [[ "$UNATTENDED" == false ]]; then
      read -rp "Remove config file ${CONFIG_FILE}? [y/N] " answer
      case "$answer" in
        [yY]*)
          rm -f "$CONFIG_FILE"
          rmdir "$CONFIG_DIR" 2>/dev/null || true
          ;;
        *)
          log "Keeping config file."
          ;;
      esac
    else
      rm -f "$CONFIG_FILE"
      rmdir "$CONFIG_DIR" 2>/dev/null || true
    fi
  fi

  # Remove PAM lines if they exist.
  if [[ -f "$PAM_SSHD" ]]; then
    sed -i '/# ntfy SSH notifications/d' "$PAM_SSHD" || true
    sed -i '/pam_exec\.so.*ntfy-ssh-notify/d' "$PAM_SSHD" || true
  fi

  systemctl daemon-reload 2>/dev/null || true
  log "Uninstall complete."
  exit 0
fi

# --- Install mode -----------------------------------------------------------
require_root
require_cmd curl
require_cmd systemctl

if [[ "$USE_PAM" == true ]]; then
  log "PAM hook selected."
  if [[ ! -f "${SCRIPT_DIR}/ntfy-ssh-notify.sh" ]]; then
    error "PAM hook script not found: ${SCRIPT_DIR}/ntfy-ssh-notify.sh"
  fi
else
  log "Auth-log watcher selected (default)."
  if [[ ! -f "${SCRIPT_DIR}/ntfy-ssh-authlog.sh" ]]; then
    error "Auth-log watcher script not found: ${SCRIPT_DIR}/ntfy-ssh-authlog.sh"
  fi
  if [[ ! -f "${SCRIPT_DIR}/ntfy-ssh-authlog.service" ]]; then
    error "Systemd service file not found: ${SCRIPT_DIR}/ntfy-ssh-authlog.service"
  fi
fi

# Detect log backend and warn if nothing looks usable.
if [[ "$USE_PAM" == false ]]; then
  if [[ -r "/var/log/auth.log" ]]; then
    log "Detected auth.log backend."
  elif command -v journalctl >/dev/null 2>&1; then
    log "Detected journalctl backend."
  else
    error "No readable /var/log/auth.log and no journalctl found. Cannot install auth-log watcher."
  fi
fi

# Gather configuration.
ntfy_endpoint="${NTFY_ENDPOINT:-}"
ntfy_topic="${NTFY_TOPIC:-}"
ntfy_access_token="${NTFY_ACCESS_TOKEN:-}"
ntfy_login_priority="${NTFY_LOGIN_PRIORITY:-3}"
ntfy_logout_priority="${NTFY_LOGOUT_PRIORITY:-2}"
ntfy_failed_priority="${NTFY_FAILED_PRIORITY:-4}"

if [[ "$UNATTENDED" == true ]]; then
  if [[ -z "$ntfy_endpoint" || -z "$ntfy_topic" ]]; then
    error "NTFY_ENDPOINT and NTFY_TOPIC must be set for unattended install."
  fi
else
  while [[ -z "$ntfy_endpoint" ]]; do
    read -rp "ntfy server endpoint (e.g. https://ntfy.example.com): " ntfy_endpoint
  done
  while [[ -z "$ntfy_topic" ]]; do
    read -rp "ntfy topic: " ntfy_topic
  done
  if [[ -z "$ntfy_access_token" ]]; then
    read -rsp "ntfy access token (optional, press Enter to skip): " ntfy_access_token
    echo
  fi
fi

# Normalise endpoint.
ntfy_endpoint="${ntfy_endpoint%/}"

# Create config directory.
mkdir -p "$CONFIG_DIR"
chmod 755 "$CONFIG_DIR"

# Backup existing config.
if [[ -f "$CONFIG_FILE" ]]; then
  backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_FILE" "$backup"
  log "Backed up existing config to ${backup}"
fi

# Write config.
cat > "$CONFIG_FILE" <<EOF
# ntfy SSH notification configuration
# Generated by install-ntfy-ssh-alerts.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')

NTFY_ENDPOINT=${ntfy_endpoint}
NTFY_TOPIC=${ntfy_topic}
NTFY_ACCESS_TOKEN=${ntfy_access_token}

# Priority levels: 1=min, 5=max
NTFY_LOGIN_PRIORITY=${ntfy_login_priority}
NTFY_LOGOUT_PRIORITY=${ntfy_logout_priority}
NTFY_FAILED_PRIORITY=${ntfy_failed_priority}
EOF
chmod 600 "$CONFIG_FILE"
chown root:root "$CONFIG_FILE" 2>/dev/null || true
log "Wrote ${CONFIG_FILE}"

if [[ "$USE_PAM" == true ]]; then
  # Install PAM hook.
  install -m 755 -o root -g root "${SCRIPT_DIR}/ntfy-ssh-notify.sh" "$PAM_SCRIPT"
  log "Installed ${PAM_SCRIPT}"

  if [[ ! -f "$PAM_SSHD" ]]; then
    error "${PAM_SSHD} not found. PAM hook cannot be installed."
  fi

  # Add PAM lines only if they are not already present.
  if ! grep -q "ntfy-ssh-notify.sh" "$PAM_SSHD"; then
    pam_block=$'\n# ntfy SSH notifications\nauth    [default=ignore]  pam_exec.so seteuid '"${PAM_SCRIPT}"$'\nsession optional          pam_exec.so seteuid '"${PAM_SCRIPT}"$'\n'

    # Insert before the first pam_deny or pam_permit line, or append if none.
    marker_line=$(grep -n -m1 -E "^\s*(auth|session)\s+(required|requisite|sufficient|optional|\[.*)\s+pam_(deny|permit)" "$PAM_SSHD" | cut -d: -f1 | head -1)
    if [[ -n "$marker_line" ]]; then
      tmp_pam=$(mktemp)
      printf '%s' "$pam_block" > "$tmp_pam"
      sed -i "${marker_line}r ${tmp_pam}" "$PAM_SSHD"
      rm -f "$tmp_pam"
    else
      cat >> "$PAM_SSHD" <<EOF
${pam_block}
EOF
    fi
    log "Updated ${PAM_SSHD}"
  else
    log "PAM lines already present in ${PAM_SSHD}"
  fi

  # PAM hook does not use the systemd service; remove any leftover service.
  if [[ -f "$SERVICE_FILE" ]]; then
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && systemctl stop "$SERVICE_NAME" || true
    systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && systemctl disable "$SERVICE_NAME" || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
  fi
else
  # Install auth-log watcher and systemd service.
  install -m 755 -o root -g root "${SCRIPT_DIR}/ntfy-ssh-authlog.sh" "$WATCHER_SCRIPT"
  install -m 644 -o root -g root "${SCRIPT_DIR}/ntfy-ssh-authlog.service" "$SERVICE_FILE"
  log "Installed ${WATCHER_SCRIPT} and ${SERVICE_FILE}"

  # Syntax check.
  if ! bash -n "$WATCHER_SCRIPT"; then
    error "Syntax check failed for ${WATCHER_SCRIPT}"
  fi

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  log "Enabled and started ${SERVICE_NAME}"
fi

# Test notification.
log "Sending test notification..."
test_url="${ntfy_endpoint}/${ntfy_topic}"
test_headers=(-H "Title: SSH alert test" -H "Tags: computer,ssh,test" -H "X-Priority: 3")
if [[ -n "$ntfy_access_token" ]]; then
  test_headers+=("-H" "Authorization: Bearer ${ntfy_access_token}")
fi

if curl --silent --show-error --fail --max-time 10 \
  "${test_headers[@]}" \
  --data-raw "ntfy SSH alerts are configured on $(hostname -s 2>/dev/null || hostname)." \
  "$test_url" >/dev/null 2>&1; then
  log "Test notification sent successfully."
else
  log "WARNING: Test notification failed. Check your endpoint, topic, and access token."
fi

# Final status.
if [[ "$USE_PAM" == true ]]; then
  log "PAM hook installed. Open a new SSH session to test."
else
  log "Installation complete."
  systemctl status --no-pager "$SERVICE_NAME" || true
fi
