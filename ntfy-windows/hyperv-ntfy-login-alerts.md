# Windows Login/Logoff Alerts via ntfy (Hyper-V Server Core)

Configure a Hyper-V Server Core host to send an [ntfy](https://ntfy.sh) push notification whenever someone logs in, logs out, or fails to log in.

**How it works:** Windows Event Viewer logs a security event on logon/logoff → Task Scheduler is triggered by that event → a PowerShell script runs and posts a message to your ntfy topic.

---

## Quick install (recommended)

1. Copy the installer to the Hyper-V host:

   ```powershell
   # From your management machine
   Copy-Item -Path ".\ntfy-windows\install-ntfy-logon-alerts.ps1" `
     -Destination "C:\Users\Administrator\Downloads\install-ntfy-logon-alerts.ps1" `
     -ToSession (New-PSSession -ComputerName hyperv-host)
   ```

   Or simply place the file on the host any way you prefer.

2. On the Hyper-V host, open an **elevated PowerShell** prompt and run:

   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
   C:\Users\Administrator\Downloads\install-ntfy-logon-alerts.ps1
   ```

   You will be prompted for the ntfy endpoint, topic, and optionally an access token.

3. Test by logging off and back on. You should receive an ntfy alert for both the logoff and the next login.

### Unattended install

```powershell
C:\Users\Administrator\Downloads\install-ntfy-logon-alerts.ps1 `
  -NtfyEndpoint https://ntfy.example.com `
  -NtfyTopic hyperv-alerts `
  -NtfyAccessToken tk_xxxxxxxx
```

### Uninstall

```powershell
C:\Users\Administrator\Downloads\install-ntfy-logon-alerts.ps1 -Uninstall
```

### Preview without making changes

```powershell
C:\Users\Administrator\Downloads\install-ntfy-logon-alerts.ps1 -WhatIf
```

---

## Updating an existing install

Re-running the installer overwrites `notify-login.ps1` in `-InstallPath` and re-registers the task in place. Nothing else on the host is touched. Two things to check first:

**The path the task actually uses.** The default is `C:\Scripts`. If an earlier install used a different directory, a bare re-run leaves the old script orphaned and points the task at a second copy:

```powershell
(Get-ScheduledTask -TaskName NtfyLogonAlert).Actions | Select-Object Execute, Arguments
```

**The credentials.** The installer does not read the endpoint/topic/token out of an existing script — it prompts — so have them ready. They're recoverable from the deployed script if you no longer have them:

```powershell
Get-Content C:\Scripts\notify-login.ps1
```

Back up a hand-edited script before overwriting it, and note that a re-registered task always comes back **enabled**, even if you had disabled it:

```powershell
Copy-Item C:\Scripts\notify-login.ps1 C:\Scripts\notify-login.ps1.bak
```

## Disabling alerts

```powershell
Disable-ScheduledTask -TaskName NtfyLogonAlert   # alerts stop; task and script stay in place
Enable-ScheduledTask  -TaskName NtfyLogonAlert   # back on
```

Disabling survives reboots but **not** a reinstall. To remove everything — task, script, and throttle state — use `-Uninstall`.

---

## Installer parameters

| Parameter | Default | Description |
|---|---|---|
| `-NtfyEndpoint` | prompted | ntfy server URL, e.g. `https://ntfy.example.com` |
| `-NtfyTopic` | prompted | ntfy topic to publish to |
| `-NtfyAccessToken` | prompted (secure) | Optional Bearer token |
| `-InstallPath` | `C:\Scripts` | Directory for `notify-login.ps1` |
| `-TaskName` | `NtfyLogonAlert` | Scheduled task name |
| `-ThrottleSeconds` | `60` | Suppress repeat alerts for the same user+IP+logon type within N seconds (`0` disables). Failed logons are never throttled |
| `-Uninstall` | switch | Remove task, script, and throttle state |
| `-WhatIf` | switch | Preview changes |

---

## Manual install

If you prefer to set things up manually, the steps below are equivalent to what the installer does.

### 1. Enable Logon Auditing

Server Core has no GUI, so this is done via `auditpol`:

```powershell
auditpol /set /subcategory:"Logon" /success:enable /failure:enable
```

This ensures Event ID 4624 (successful logon) and 4625 (failed logon) get written to the Security log. Logoff events 4634/4647 do not need separate auditing; they are logged by default once logon auditing is enabled.

### 2. Create the Notification Script

Save as `C:\Scripts\notify-login.ps1` (identical to what the installer writes):

```powershell
param(
    [int]$ThrottleSeconds = 60,
    [switch]$SelfTest
)

function Test-NtfyShouldSend {
    param([int]$EventId, [string]$Key, [string]$StatePath, [int]$WindowSeconds)

    if ($EventId -eq 4625) { return $true }
    if ($WindowSeconds -le 0) { return $true }

    $now = (Get-Date).Ticks
    if (Test-Path $StatePath) {
        try {
            $parts = (Get-Content -Path $StatePath -Raw -ErrorAction Stop).Trim() -split '\|', 2
            if ($parts.Count -eq 2 -and $parts[1] -eq $Key -and ($now - [int64]$parts[0]) -lt ($WindowSeconds * 10000000)) {
                return $false
            }
        } catch { }
    }

    # Fail open: if the state file can't be written we send anyway.
    try { Set-Content -Path $StatePath -Value ($now.ToString() + '|' + $Key) -Encoding ASCII -ErrorAction Stop } catch { }
    return $true
}

if ($SelfTest) {
    function Assert-True($Condition, $Message) { if (-not $Condition) { throw "FAIL: $Message" } }
    $t = Join-Path ([IO.Path]::GetTempPath()) "ntfy-throttle-selftest.txt"
    Remove-Item $t -ErrorAction SilentlyContinue

    Assert-True (Test-NtfyShouldSend 4624 "alice|10.0.0.5|3" $t 60) "first logon sends"
    Assert-True (-not (Test-NtfyShouldSend 4624 "alice|10.0.0.5|3" $t 60)) "repeat logon suppressed"
    Assert-True (Test-NtfyShouldSend 4624 "bob|10.0.0.9|3" $t 60) "different user sends"
    Assert-True (Test-NtfyShouldSend 4625 "alice|10.0.0.5|3" $t 60) "failed logon sends"
    Assert-True (Test-NtfyShouldSend 4625 "alice|10.0.0.5|3" $t 60) "failed logon never throttled"
    Assert-True (Test-NtfyShouldSend 4624 "alice|10.0.0.5|3" $t 0) "throttle disabled sends"

    Remove-Item $t -ErrorAction SilentlyContinue
    Write-Output "Self-test passed"
    exit 0
}

$computer = $env:COMPUTERNAME
$time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Read the most recent logon/logoff/security event that triggered this task
try {
    $event = Get-WinEvent -LogName Security -MaxEvents 1 -FilterXPath "*[System[(EventID=4624 or EventID=4625 or EventID=4634 or EventID=4647)]]"
} catch {
    Write-Output "Could not read Security event: $_"
    exit 0
}

$xml = [xml]$event.ToXml()

$eventId = $event.Id
$user = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'
$sourceIp = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'IpAddress' }).'#text'
if (-not $sourceIp -or $sourceIp -eq '-') { $sourceIp = 'local' }
$logonType = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'LogonType' }).'#text'
if (-not $logonType) { $logonType = '-' }

# Drop the WinRM/WAC burst before posting anything.
$stateDir = Join-Path $env:ProgramData "ntfy-logon-alerts"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
if (-not (Test-NtfyShouldSend $eventId ("$user|$sourceIp|$logonType") (Join-Path $stateDir "throttle.txt") $ThrottleSeconds)) {
    exit 0
}

# Common logon types
$logonTypeMap = @{ "2"="Console"; "3"="Network"; "10"="RemoteDesktop"; "5"="Service" }

switch ($eventId) {
    4625 {
        # Failed logon
        $title = "Hyper-V Host Failed Login"
        $body = "Failed login for $user from $sourceIp at $time"
        $priority = "urgent"
        $tags = "warning,security,failed-login"
    }
    { $_ -in 4634, 4647 } {
        # Logoff
        $title = "Hyper-V Host Logoff"
        $body = "Logoff by $user from $sourceIp at $time"
        $priority = "low"
        $tags = "computer,logoff"
    }
    default {
        # Successful logon (4624)
        $typeText = $logonTypeMap[$logonType]
        if (-not $typeText) { $typeText = "Type $logonType" }

        $title = "Hyper-V Host Login Alert"
        $body = "Login on $computer by $user ($typeText) from $sourceIp at $time"
        $priority = "high"
        $tags = "server,warning"
    }
}

$headers = @{
    "Title" = $title
    "Priority" = $priority
    "Tags" = $tags
}

# **If your ntfy server requires auth**, uncomment the next line and add your token:
# $headers["Authorization"] = "Bearer YOUR_TOKEN"

try {
    Invoke-RestMethod -Uri "https://your-ntfy-server.com/your-topic" `
      -Method Post `
      -Body $body `
      -Headers $headers
} catch {
    # A failed notification must never block logon
    Write-Output "ntfy notification failed: $_"
}
```

Avoid hardcoding secrets in plaintext where possible — consider an environment variable or Windows Credential Manager wrapper.

### 3. Register the Scheduled Task

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument '-ExecutionPolicy Bypass -File "C:\Scripts\notify-login.ps1"'

$CIMTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$trigger = New-CimInstance -CimClass $CIMTriggerClass -ClientOnly
$trigger.Subscription =
@"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">*[System[(EventID=4624 or EventID=4625 or EventID=4634 or EventID=4647)]]</Select>
  </Query>
</QueryList>
"@
$trigger.Enabled = $true

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "NtfyLogonAlert" `
  -Action $action -Trigger $trigger -Principal $principal `
  -Description "Sends ntfy alert on logon, logoff, and failed logons"
```

`SYSTEM` is used as the principal so no credentials need to be stored, and it has permission to read the Security log.

> This single task triggers on **4624** (successful logon), **4625** (failed logon), and **4634/4647** (logoff). The script inspects the event ID to decide the message, priority, and tags.

---

## Notes & Gotchas

- **Run this on the Hyper-V host (parent partition)**, not inside a guest VM — this tracks who's logging into the hypervisor itself, which controls all your VMs.
- If managing the host via WinRM/PowerShell remoting (typical for Core), logon type will usually show as `3` (Network) rather than `RemoteDesktop` — that's expected, not an error.
- Since this host is more sensitive than a regular endpoint, alerting on **4625 (failed logons)** too is worth doing — it can help catch brute-force attempts.
- Confirm outbound network access from the Windows box to your ntfy server actually works (relevant if you're dealing with any IP-blocking/firewall issues on the ntfy server side).
- Logoff events are lower priority and quieter. A single RDP session may produce a 4634 when disconnecting and another when fully logging off.

## Windows Admin Center

**Windows Admin Center connections are detected.**

Windows Admin Center connects to the Hyper-V host over WinRM (HTTPS 5986 / HTTP 5985). Every successful admin authentication writes a **Security Event ID 4624** on the host with:

- **LogonType 3** (Network)
- **IpAddress** of the machine running Windows Admin Center
- **TargetUserName** of the account used to connect

This means the `NtfyLogonAlert` task will fire when someone opens Windows Admin Center against the host, whether they click through to Hyper-V, File and Storage Services, or any other extension.

**Throttling.** Windows Admin Center issues multiple WinRM calls during a session, so a single visit produces several 4624 events in a row — all identical in user, IP, and logon type. Without a throttle that's one alert per WinRM call. `notify-login.ps1` therefore keeps the last alert's key in `%ProgramData%\ntfy-logon-alerts\throttle.txt` and drops any repeat of the same **user + IP + logon type** within `-ThrottleSeconds` (default 60).

- A genuinely new logon — different user or different source machine — always alerts, so the throttle can't hide a real second session.
- **Failed logons (4625) are never throttled.** A brute-force burst is exactly the signal you want several of.
- Set `-ThrottleSeconds 0` to disable, or raise it (e.g. `300`) if a long WAC session still trickles through.
- To verify the logic on the host: `powershell -ExecutionPolicy Bypass -File C:\Scripts\notify-login.ps1 -SelfTest` — prints `Self-test passed` or throws `FAIL: <case>`.

If the throttle isn't enough because you don't care about WAC logins at all, the alternative is to drop `LogonType 3` from the task trigger's XPath — but that also silences PowerShell remoting and any other network logon to the host, which on a hypervisor is usually worth knowing about.

## Optional Extension

For RDP-specific session alerts (separate from general logon events), use Event IDs 21/25 from the **TerminalServices-RemoteConnectionManager** log instead of the Security log's 4624 — same script/task pattern applies, just change the log path and Event ID in the XPath filter and task trigger.
