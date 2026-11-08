#!/usr/bin/env bash
# ntfy SSH notification watcher for auth log events.
# Alternative to the PAM hook. Runs as a systemd service.
#
# Install:
#   sudo cp ntfy-ssh-authlog.sh /usr/local/bin/ntfy-ssh-authlog.sh
#   sudo chmod 755 /usr/local/bin/ntfy-ssh-authlog.sh
#   sudo cp ntfy-ssh-authlog.service /etc/systemd/system/ntfy-ssh-authlog.service
#   sudo systemctl daemon-reload
#   sudo systemctl enable --now ntfy-ssh-authlog
#
# This script uses the same config file as the PAM hook:
#   /etc/ntfy-ssh/ntfy-ssh.conf
#
# The script auto-detects the log backend:
#   - /var/log/auth.log on Debian/Ubuntu and other syslog-based systems
#   - journalctl -u sshd on RHEL/CentOS/Fedora/Arch/Amazon Linux and other
#     systemd-journald based systems

set -euo pipefail

CONFIG_FILE="/etc/ntfy-ssh/ntfy-ssh.conf"

# Defaults
NTFY_ENDPOINT=""
NTFY_TOPIC=""
NTFY_ACCESS_TOKEN=""
NTFY_LOGIN_PRIORITY="3"
NTFY_LOGOUT_PRIORITY="2"
NTFY_FAILED_PRIORITY="4"

if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  set -a
  source "$CONFIG_FILE"
  set +a
fi

if [[ -z "$NTFY_ENDPOINT" || -z "$NTFY_TOPIC" ]]; then
  echo "Config missing: ${CONFIG_FILE}" >&2
  exit 1
fi

NTFY_ENDPOINT="${NTFY_ENDPOINT%/}"
URL="${NTFY_ENDPOINT}/${NTFY_TOPIC}"

HOSTNAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
AUTH_LOG="/var/log/auth.log"

send_ntfy() {
  local title="$1"
  local message="$2"
  local tags="$3"
  local priority="$4"

  local headers=(-H "Title: ${title}" -H "Tags: ${tags}" -H "X-Priority: ${priority}")
  if [[ -n "$NTFY_ACCESS_TOKEN" ]]; then
    headers+=("-H" "Authorization: Bearer ${NTFY_ACCESS_TOKEN}")
  fi

  curl --silent --show-error --fail --max-time 10 \
    "${headers[@]}" \
    --data-raw "$message" \
    "$URL" >/dev/null 2>&1 || true
}

# Determine the best available log backend.
choose_backend() {
  if [[ -r "$AUTH_LOG" ]]; then
    echo "authlog"
    return
  fi

  # Debian/Ubuntu use ssh.service; RHEL/CentOS/Fedora/Arch use sshd.service.
  if command -v journalctl >/dev/null 2>&1 && \
     (systemctl cat sshd.service >/dev/null 2>&1 || systemctl cat ssh.service >/dev/null 2>&1); then
    echo "journalctl"
    return
  fi

  # Last resort: try journalctl anyway; it will fail cleanly if unavailable.
  if command -v journalctl >/dev/null 2>&1; then
    echo "journalctl"
    return
  fi

  echo "none"
}

BACKEND="$(choose_backend)"

if [[ "$BACKEND" == "none" ]]; then
  echo "Cannot read ${AUTH_LOG} and journalctl is not available." >&2
  exit 1
fi

# Pre-compile regexes in variables to avoid bash [[ =~ ]] quoting issues.
re_login='Accepted (password|publickey|keyboard-interactive) for ([^ ]+) from ([^ ]+)'
re_failed='Failed (password|publickey) for (invalid user )?([^ ]+) from ([^ ]+)'
re_invalid='Invalid user ([^ ]+) from ([^ ]+)'
# Connection closed lines vary between OpenSSH versions and distros:
#   Connection closed by 192.0.2.1 port 54321
#   Connection closed by 192.0.2.1
#   Connection closed by authenticating user root 192.0.2.1 port 54321 [preauth]
re_logout='Connection closed by( authenticating user [^ ]+)? ([^ ]+)( port [0-9]+)?( \[preauth\])?'

process_line() {
  local line="$1"

  # Skip non-SSH lines and preauth noise.
  [[ "$line" == *"sshd"* ]] || return
  [[ "$line" == *"[preauth]"* ]] && return

  # Parse accepted login.
  if [[ "$line" =~ $re_login ]]; then
    local user="${BASH_REMATCH[2]}"
    local ip="${BASH_REMATCH[3]}"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    send_ntfy "SSH login: ${HOSTNAME}" \
      "User ${user} logged in from ${ip} at ${timestamp}" \
      "computer,ssh,login" \
      "$NTFY_LOGIN_PRIORITY"
    return
  fi

  # Parse failed login (Failed password/publickey).
  if [[ "$line" =~ $re_failed ]]; then
    local user="${BASH_REMATCH[3]}"
    local ip="${BASH_REMATCH[4]}"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    send_ntfy "SSH failed: ${HOSTNAME}" \
      "Failed login for ${user} from ${ip} at ${timestamp}" \
      "warning,ssh,failed" \
      "$NTFY_FAILED_PRIORITY"
    return
  fi

  # Parse invalid user (key-based or nonexistent user).
  if [[ "$line" =~ $re_invalid ]]; then
    local user="${BASH_REMATCH[1]}"
    local ip="${BASH_REMATCH[2]}"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    send_ntfy "SSH failed: ${HOSTNAME}" \
      "Invalid user ${user} from ${ip} at ${timestamp}" \
      "warning,ssh,failed" \
      "$NTFY_FAILED_PRIORITY"
    return
  fi

  # Parse connection closed (logout).
  if [[ "$line" =~ $re_logout ]]; then
    local ip="${BASH_REMATCH[2]}"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    # Sanity-check that the captured group looks like an IP/hostname.
    # If it is a literal word such as "authenticating", skip it.
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$ip" =~ : || "$ip" =~ \. ]]; then
      send_ntfy "SSH logout: ${HOSTNAME}" \
        "Connection closed by ${ip} at ${timestamp}" \
        "computer,ssh,logout" \
        "$NTFY_LOGOUT_PRIORITY"
    fi
    return
  fi
}

# Stream events from the chosen backend.
if [[ "$BACKEND" == "authlog" ]]; then
  tail -F -n 0 "$AUTH_LOG" 2>&1 | while read -r line; do
    process_line "$line"
  done
else
  # -n 0 means follow new entries only; --no-pager avoids hanging on old systems.
  # Cover the common SSH service names: sshd.service (RHEL/Fedora/Arch), ssh.service (Debian/Ubuntu).
  journalctl -u sshd.service -u sshd -u ssh.service -f -n 0 --no-pager 2>&1 | while read -r line; do
    process_line "$line"
  done
fi
