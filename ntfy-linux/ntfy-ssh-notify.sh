#!/usr/bin/env bash
# ntfy SSH notification hook for PAM.
# Triggered by /etc/pam.d/sshd for successful logins, logouts, and failed auth.
#
# Install:
#   sudo mkdir -p /etc/ntfy-ssh
#   sudo cp ntfy-ssh-notify.conf.example /etc/ntfy-ssh/ntfy-ssh.conf
#   sudo chmod 600 /etc/ntfy-ssh/ntfy-ssh.conf
#   sudo cp ntfy-ssh-notify.sh /usr/local/bin/ntfy-ssh-notify.sh
#   sudo chmod 755 /usr/local/bin/ntfy-ssh-notify.sh
#
# Add to /etc/pam.d/sshd (before any pam_deny lines, keep optional):
#   auth    optional     pam_exec.so seteuid /usr/local/bin/ntfy-ssh-notify.sh
#   session optional     pam_exec.so seteuid /usr/local/bin/ntfy-ssh-notify.sh

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
  # Silently exit if not configured; PAM must not block logins.
  exit 0
fi

# Trim trailing slash
NTFY_ENDPOINT="${NTFY_ENDPOINT%/}"
URL="${NTFY_ENDPOINT}/${NTFY_TOPIC}"

USER="${PAM_USER:-unknown}"
RHOST="${PAM_RHOST:-unknown}"
RUSER="${PAM_RUSER:-}"
SERVICE="${PAM_SERVICE:-unknown}"
TTY="${PAM_TTY:-unknown}"
TYPE="${PAM_TYPE:-unknown}"

HOSTNAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
TIMESTAMP="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# Build notification based on PAM type
case "$TYPE" in
  open_session)
    TITLE="SSH login: ${HOSTNAME}"
    MESSAGE="User ${USER} logged in via ${SERVICE} from ${RHOST} at ${TIMESTAMP}"
    TAGS="computer,ssh,login"
    PRIORITY="${NTFY_LOGIN_PRIORITY}"
    ;;
  close_session)
    TITLE="SSH logout: ${HOSTNAME}"
    MESSAGE="User ${USER} logged out from ${SERVICE} (${RHOST}) at ${TIMESTAMP}"
    TAGS="computer,ssh,logout"
    PRIORITY="${NTFY_LOGOUT_PRIORITY}"
    ;;
  auth|account)
    # Only send on failures; successful auth is followed by open_session.
    # PAM does not set a failure flag directly in env, but if PAM_AUTHTOK/PAM_OLDAUTHTOK are absent,
    # we rely on the fact that this script is invoked only for the 'auth' stack when auth fails
    # if combined with the right control flag. To avoid duplicate noise, we don't send here by
    # default; instead, failed attempts are better captured by monitoring /var/log/auth.log.
    #
    # If you DO want per-failure auth notifications from PAM, change the PAM line to:
    #   auth [default=ignore] pam_exec.so seteuid /usr/local/bin/ntfy-ssh-notify.sh
    # and set NTFY_SEND_AUTH_FAILURES=true in the config.
    if [[ "${NTFY_SEND_AUTH_FAILURES:-false}" != "true" ]]; then
      exit 0
    fi
    TITLE="SSH auth failure: ${HOSTNAME}"
    MESSAGE="Failed ${TYPE} attempt for ${USER} from ${RHOST} via ${SERVICE} at ${TIMESTAMP}"
    TAGS="warning,ssh,failed"
    PRIORITY="${NTFY_FAILED_PRIORITY}"
    ;;
  *)
    exit 0
    ;;
esac

HEADERS=(-H "Title: ${TITLE}" -H "Tags: ${TAGS}" -H "X-Priority: ${PRIORITY}")
if [[ -n "$NTFY_ACCESS_TOKEN" ]]; then
  HEADERS+=("-H" "Authorization: Bearer ${NTFY_ACCESS_TOKEN}")
fi

# Send notification; never block PAM on failure.
curl --silent --show-error --fail --max-time 10 \
  "${HEADERS[@]}" \
  --data-raw "$MESSAGE" \
  "$URL" >/dev/null 2>&1 || true

exit 0
