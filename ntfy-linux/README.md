# ntfy SSH Notifications

Send real-time ntfy alerts when someone SSHs into a Linux server.

You need an ntfy server: the hosted [ntfy.sh](https://ntfy.sh) service (free tier or paid plans) or a self-hosted [binwiederhier/ntfy](https://github.com/binwiederhier/ntfy) instance.

Two approaches are provided:

1. **Auth-log watcher** (`ntfy-ssh-authlog.sh` + systemd service) — recommended; tails `/var/log/auth.log` or `journalctl -u sshd`
2. **PAM hook** (`ntfy-ssh-notify.sh`) — runs inside the SSH auth/session stack

The auth-log watcher is simpler to maintain and doesn't touch PAM. The PAM hook is slightly more immediate for logins but adds a small dependency to every SSH session.

## Files

- `install-ntfy-ssh-alerts.sh` — reusable installer (recommended)
- `ntfy-ssh-authlog.sh` — auth-log tail watcher
- `ntfy-ssh-authlog.service` — systemd unit for the watcher
- `ntfy-ssh-notify.sh` — PAM hook script
- `ntfy-ssh-notify.conf.example` — configuration template
- `README.md` — this file

## Quick install (recommended)

Copy the installer and source files to the target server, then run it:

```bash
scp ntfy-linux/install-ntfy-ssh-alerts.sh \
   ntfy-linux/ntfy-ssh-authlog.sh \
   ntfy-linux/ntfy-ssh-authlog.service \
   user@example.com:/tmp/
ssh user@example.com 'sudo bash /tmp/install-ntfy-ssh-alerts.sh'
```

The installer will prompt for the ntfy endpoint, topic, and access token.

### Unattended install

For automation, set the configuration via environment variables and use `-y`:

```bash
ssh user@example.com '
  sudo NTFY_ENDPOINT=https://ntfy.example.com \
       NTFY_TOPIC=ssh-alerts \
       NTFY_ACCESS_TOKEN=ntfy_xxxxxxxxxxxxxxxx \
       bash /tmp/install-ntfy-ssh-alerts.sh -y
'
```

Optional environment variables:

- `NTFY_LOGIN_PRIORITY` — default `3`
- `NTFY_LOGOUT_PRIORITY` — default `2`
- `NTFY_FAILED_PRIORITY` — default `4`

### Install the PAM hook instead

Use the `--pam` flag if you prefer the PAM hook:

```bash
sudo NTFY_ENDPOINT=https://ntfy.example.com NTFY_TOPIC=ssh-alerts bash /tmp/install-ntfy-ssh-alerts.sh --pam
```

### Uninstall

```bash
sudo bash /tmp/install-ntfy-ssh-alerts.sh --uninstall
```

## Shared configuration

Both scripts read `/etc/ntfy-ssh/ntfy-ssh.conf`:

```text
NTFY_ENDPOINT=https://ntfy.example.com
NTFY_TOPIC=ssh-alerts
NTFY_ACCESS_TOKEN=ntfy_xxxxxxxxxxxxxxxx
```

Keep the file at `600` and owned by `root`.

---

## Manual install: auth-log watcher

1. Copy the script, config, and systemd unit to the server:

   ```bash
   ssh user@example.com "sudo mkdir -p /etc/ntfy-ssh"
   scp ntfy-linux/ntfy-ssh-notify.conf.example user@example.com:/tmp/ntfy-ssh.conf
   scp ntfy-linux/ntfy-ssh-authlog.sh user@example.com:/tmp/ntfy-ssh-authlog.sh
   scp ntfy-linux/ntfy-ssh-authlog.service user@example.com:/tmp/ntfy-ssh-authlog.service
   ssh user@example.com '
     sudo mv /tmp/ntfy-ssh.conf /etc/ntfy-ssh/ntfy-ssh.conf
     sudo chmod 600 /etc/ntfy-ssh/ntfy-ssh.conf
     sudo mv /tmp/ntfy-ssh-authlog.sh /usr/local/bin/ntfy-ssh-authlog.sh
     sudo chmod 755 /usr/local/bin/ntfy-ssh-authlog.sh
     sudo mv /tmp/ntfy-ssh-authlog.service /etc/systemd/system/ntfy-ssh-authlog.service
     sudo systemctl daemon-reload
     sudo systemctl enable --now ntfy-ssh-authlog
   '
   ```

2. Edit `/etc/ntfy-ssh/ntfy-ssh.conf` on the server and set your endpoint, topic, and access token.

3. Test by opening a new SSH session and checking the service status:

   ```bash
   ssh user@example.com 'sudo systemctl status ntfy-ssh-authlog'
   ```

---

## Manual install: PAM hook

1. Copy the script and config to the server:

   ```bash
   ssh user@example.com "sudo mkdir -p /etc/ntfy-ssh"
   scp ntfy-linux/ntfy-ssh-notify.conf.example user@example.com:/tmp/ntfy-ssh.conf
   scp ntfy-linux/ntfy-ssh-notify.sh user@example.com:/tmp/ntfy-ssh-notify.sh
   ssh user@example.com '
     sudo mv /tmp/ntfy-ssh.conf /etc/ntfy-ssh/ntfy-ssh.conf
     sudo chmod 600 /etc/ntfy-ssh/ntfy-ssh.conf
     sudo mv /tmp/ntfy-ssh-notify.sh /usr/local/bin/ntfy-ssh-notify.sh
     sudo chmod 755 /usr/local/bin/ntfy-ssh-notify.sh
   '
   ```

2. Edit `/etc/ntfy-ssh/ntfy-ssh.conf` on the server and set your endpoint, topic, and access token.

3. Add the hook to `/etc/pam.d/sshd`:

   ```text
   # ntfy SSH notifications
   auth    [default=ignore]  pam_exec.so seteuid /usr/local/bin/ntfy-ssh-notify.sh
   session optional          pam_exec.so seteuid /usr/local/bin/ntfy-ssh-notify.sh
   ```

   Place the `auth` line before any `pam_deny` or `pam_permit` lines, and keep it marked `optional` or `[default=ignore]` so a notification failure never locks you out.

4. Open a new SSH session to test. You should receive an ntfy alert.

---

## What is reported

- **Login** — user, source IP, hostname, timestamp
- **Logout** — source IP, hostname, timestamp
- **Failed login attempts** — invalid user / failed password / failed publickey, source IP, hostname, timestamp

## Distro support

The installer has been tested on Ubuntu. The auth-log watcher supports:

- Debian/Ubuntu and other systems that write SSH events to `/var/log/auth.log`
- RHEL/CentOS/Fedora/Arch/Amazon Linux and other systems that log SSH events to `journalctl -u sshd`
- Works with both `sshd.service` and `ssh.service` SSH unit names

## Security notes

- The config file contains your ntfy access token; keep it at `600` and owned by `root`.
- The PAM hook exits silently if the config is missing or invalid, so SSH logins always succeed.
- curl has a 10-second timeout so a slow ntfy server won't hang SSH or the watcher.
