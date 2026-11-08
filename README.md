# ntfy Server Alerts

Reusable ntfy alerting stack for server logon/logoff events on Linux and Windows.

## Linux: SSH alerts

Sends real-time ntfy notifications for:
- SSH login
- SSH logout
- Failed SSH authentication attempts

## Windows: Hyper-V Server Core alerts

Sends real-time ntfy notifications for:
- Logon (RDP, console, WinRM, Windows Admin Center)
- Logoff
- Failed logon attempts

## Project layout

```
ntfy-server-alerts/
├── ntfy-linux/
│   ├── install-ntfy-ssh-alerts.sh      # Linux reusable installer
│   ├── ntfy-ssh-authlog.sh             # Auth-log / journalctl watcher
│   ├── ntfy-ssh-authlog.service        # systemd unit
│   ├── ntfy-ssh-notify.sh              # Optional PAM hook
│   ├── ntfy-ssh-notify.conf.example    # Config template
│   └── README.md                       # Linux detailed install docs
├── ntfy-windows/
│   ├── install-ntfy-logon-alerts.ps1   # Windows/Hyper-V installer
│   └── hyperv-ntfy-login-alerts.md     # Windows detailed install docs
└── README.md                           # This file
```

## Quick install: Linux

```bash
scp ntfy-linux/install-ntfy-ssh-alerts.sh \
   ntfy-linux/ntfy-ssh-authlog.sh \
   ntfy-linux/ntfy-ssh-authlog.service \
   user@new-server:/tmp/

ssh user@new-server 'sudo bash /tmp/install-ntfy-ssh-alerts.sh'
```

Unattended:

```bash
ssh user@new-server '
  sudo NTFY_ENDPOINT=https://ntfy.example.com \
       NTFY_TOPIC=ssh-alerts \
       NTFY_ACCESS_TOKEN=ntfy_xxxxxxxxxxxxxxxx \
       bash /tmp/install-ntfy-ssh-alerts.sh -y
'
```

See `ntfy-linux/README.md` for PAM hook, uninstall, manual install, and distro support details.

## Quick install: Windows Hyper-V

On the Hyper-V host, open an elevated PowerShell prompt:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
C:\Users\Administrator\Downloads\install-ntfy-logon-alerts.ps1 `
  -NtfyEndpoint https://ntfy.example.com `
  -NtfyTopic hyperv-alerts `
  -NtfyAccessToken tk_xxxxxxxx
```

See `ntfy-windows/hyperv-ntfy-login-alerts.md` for manual setup, Windows Admin Center notes, and RDP-specific extensions.

## Repository

https://github.com/Zapskii/ntfy-server-alerts

Clone or download the latest version:

```bash
git clone https://github.com/Zapskii/ntfy-server-alerts.git
```
