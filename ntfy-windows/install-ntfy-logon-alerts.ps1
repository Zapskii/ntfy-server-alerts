#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs ntfy Windows logon/logon-failure alerts via a scheduled task.

.DESCRIPTION
    Creates C:\Scripts\notify-login.ps1 and registers a scheduled task that
    triggers on Security Event IDs 4624 (successful logon) and 4625 (failed
    logon), posting a notification to an ntfy topic.

.PARAMETER NtfyEndpoint
    URL of the ntfy server, e.g. https://ntfy.example.com

.PARAMETER NtfyTopic
    ntfy topic name to publish to

.PARAMETER NtfyAccessToken
    Optional ntfy access token (Bearer auth)

.PARAMETER InstallPath
    Directory where notify-login.ps1 will be created. Default: C:\Scripts

.PARAMETER TaskName
    Name of the scheduled task. Default: NtfyLogonAlert

.PARAMETER ThrottleSeconds
    Suppress repeat alerts for the same user+IP+logon type within this many
    seconds. Windows Admin Center authenticates several times per session and
    would otherwise send one alert per WinRM call. 0 disables throttling.
    Failed logons (4625) are never throttled. Default: 60

.PARAMETER Uninstall
    Remove the scheduled task and script file

.PARAMETER WhatIf
    Show what would be done without making changes

.EXAMPLE
    .\install-ntfy-logon-alerts.ps1 -NtfyEndpoint https://ntfy.example.com -NtfyTopic hyperv-alerts

.EXAMPLE
    .\install-ntfy-logon-alerts.ps1 -NtfyEndpoint https://ntfy.example.com -NtfyTopic hyperv-alerts -NtfyAccessToken tk_xxxxxxxx -Uninstall
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$NtfyEndpoint,

    [Parameter(Mandatory = $false)]
    [string]$NtfyTopic,

    [Parameter(Mandatory = $false)]
    [string]$NtfyAccessToken,

    [Parameter(Mandatory = $false)]
    [string]$InstallPath = "C:\Scripts",

    [Parameter(Mandatory = $false)]
    [string]$TaskName = "NtfyLogonAlert",

    [Parameter(Mandatory = $false)]
    [int]$ThrottleSeconds = 60,

    [Parameter(Mandatory = $false)]
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $InstallPath "notify-login.ps1"

function Write-Info {
    param([string]$Message)
    Write-Host "[ntfy-logon-install] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[ntfy-logon-install] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[ntfy-logon-install] $Message" -ForegroundColor Yellow
}

# --- Uninstall mode ----------------------------------------------------------
if ($Uninstall) {
    if ($PSCmdlet.ShouldProcess($TaskName, "Unregister scheduled task")) {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Success "Unregistered scheduled task '$TaskName'"
        } else {
            Write-Warn "Scheduled task '$TaskName' not found"
        }
    }

    if ($PSCmdlet.ShouldProcess($scriptPath, "Remove notification script")) {
        if (Test-Path $scriptPath) {
            Remove-Item -Path $scriptPath -Force
            Write-Success "Removed $scriptPath"
        } else {
            Write-Warn "Script not found at $scriptPath"
        }
    }

    $stateDir = Join-Path $env:ProgramData "ntfy-logon-alerts"
    if (Test-Path $stateDir) {
        Remove-Item -Path $stateDir -Recurse -Force
        Write-Success "Removed $stateDir"
    }

    exit 0
}

# --- Install mode ------------------------------------------------------------
if (-not $NtfyEndpoint) {
    $NtfyEndpoint = Read-Host "ntfy server endpoint (e.g. https://ntfy.example.com)"
}
if (-not $NtfyTopic) {
    $NtfyTopic = Read-Host "ntfy topic"
}
if (-not $PSBoundParameters.ContainsKey('NtfyAccessToken')) {
    $secureToken = Read-Host "ntfy access token (optional, press Enter to skip)" -AsSecureString
    if ($secureToken.Length -gt 0) {
        $NtfyAccessToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        )
    }
}

if (-not $NtfyEndpoint -or -not $NtfyTopic) {
    throw "NtfyEndpoint and NtfyTopic are required."
}

# Normalise endpoint.
$NtfyEndpoint = $NtfyEndpoint.TrimEnd('/')
$uri = "$NtfyEndpoint/$NtfyTopic"

# Enable logon auditing.
Write-Info "Enabling logon auditing..."
if ($PSCmdlet.ShouldProcess("auditpol Logon", "Enable success and failure auditing")) {
    auditpol /set /subcategory:"Logon" /success:enable /failure:enable | Out-Null
    Write-Success "Logon auditing enabled"
}

# Create install directory.
if (-not (Test-Path $InstallPath)) {
    if ($PSCmdlet.ShouldProcess($InstallPath, "Create directory")) {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
        Write-Success "Created $InstallPath"
    }
}

# Build the notification script.
$authHeaderLine = ""
if ($NtfyAccessToken) {
    $authHeaderLine = '    "Authorization" = "Bearer ' + $NtfyAccessToken + '"'
}

$scriptContent = @"
# Generated by install-ntfy-logon-alerts.ps1 on $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# Notifies an ntfy topic for logon/logoff/security events:
#   4624 - successful logon
#   4625 - failed logon
#   4634 - account logged off
#   4647 - user initiated logoff
#
# Windows Admin Center / WinRM authenticates several times per session, which
# produces a burst of 4624 events for the same user+IP. Repeats within
# `$ThrottleSeconds seconds are suppressed. Failed logons (4625) are never
# throttled - those are the security signal.
#
# Self-check: powershell -ExecutionPolicy Bypass -File notify-login.ps1 -SelfTest

param(
    [int]`$ThrottleSeconds = $ThrottleSeconds,
    [switch]`$SelfTest
)

function Test-NtfyShouldSend {
    param([int]`$EventId, [string]`$Key, [string]`$StatePath, [int]`$WindowSeconds)

    if (`$EventId -eq 4625) { return `$true }
    if (`$WindowSeconds -le 0) { return `$true }

    `$now = (Get-Date).Ticks
    if (Test-Path `$StatePath) {
        try {
            `$parts = (Get-Content -Path `$StatePath -Raw -ErrorAction Stop).Trim() -split '\|', 2
            if (`$parts.Count -eq 2 -and `$parts[1] -eq `$Key -and (`$now - [int64]`$parts[0]) -lt (`$WindowSeconds * 10000000)) {
                return `$false
            }
        } catch { }
    }

    # Fail open: if the state file can't be written we send anyway.
    # ponytail: no lock - concurrent task instances could both send. Rare, harmless.
    try { Set-Content -Path `$StatePath -Value (`$now.ToString() + '|' + `$Key) -Encoding ASCII -ErrorAction Stop } catch { }
    return `$true
}

if (`$SelfTest) {
    function Assert-True(`$Condition, `$Message) { if (-not `$Condition) { throw "FAIL: `$Message" } }
    `$t = Join-Path ([IO.Path]::GetTempPath()) "ntfy-throttle-selftest.txt"
    Remove-Item `$t -ErrorAction SilentlyContinue

    Assert-True (Test-NtfyShouldSend 4624 "alice|10.0.0.5|3" `$t 60) "first logon sends"
    Assert-True (-not (Test-NtfyShouldSend 4624 "alice|10.0.0.5|3" `$t 60)) "repeat logon suppressed"
    Assert-True (Test-NtfyShouldSend 4624 "bob|10.0.0.9|3" `$t 60) "different user sends"
    Assert-True (Test-NtfyShouldSend 4625 "alice|10.0.0.5|3" `$t 60) "failed logon sends"
    Assert-True (Test-NtfyShouldSend 4625 "alice|10.0.0.5|3" `$t 60) "failed logon never throttled"
    Assert-True (Test-NtfyShouldSend 4624 "alice|10.0.0.5|3" `$t 0) "throttle disabled sends"

    Remove-Item `$t -ErrorAction SilentlyContinue
    Write-Output "Self-test passed"
    exit 0
}

`$computer = `$env:COMPUTERNAME
`$time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

try {
    `$event = Get-WinEvent -LogName Security -MaxEvents 1 -FilterXPath "*[System[(EventID=4624 or EventID=4625 or EventID=4634 or EventID=4647)]]"
} catch {
    Write-Output "Could not read Security event: `$_"
    exit 0
}

`$xml = [xml]`$event.ToXml()
`$eventId = `$event.Id
`$user = (`$xml.Event.EventData.Data | Where-Object { `$_.Name -eq 'TargetUserName' }).'#text'
`$sourceIp = (`$xml.Event.EventData.Data | Where-Object { `$_.Name -eq 'IpAddress' }).'#text'
if (-not `$sourceIp -or `$sourceIp -eq '-') { `$sourceIp = 'local' }
`$logonType = (`$xml.Event.EventData.Data | Where-Object { `$_.Name -eq 'LogonType' }).'#text'
if (-not `$logonType) { `$logonType = '-' }

# Drop the WinRM/WAC burst before posting anything.
`$stateDir = Join-Path `$env:ProgramData "ntfy-logon-alerts"
if (-not (Test-Path `$stateDir)) { New-Item -ItemType Directory -Path `$stateDir -Force | Out-Null }
if (-not (Test-NtfyShouldSend `$eventId ("`$user|`$sourceIp|`$logonType") (Join-Path `$stateDir "throttle.txt") `$ThrottleSeconds)) {
    exit 0
}

`$logonTypeMap = @{ "2"="Console"; "3"="Network"; "10"="RemoteDesktop"; "5"="Service" }

switch (`$eventId) {
    4625 {
        `$title = "Hyper-V Host Failed Login"
        `$body = "Failed login for `$user from `$sourceIp at `$time"
        `$priority = "urgent"
        `$tags = "warning,security,failed-login"
    }
    { `$_ -in 4634, 4647 } {
        `$title = "Hyper-V Host Logoff"
        `$body = "Logoff by `$user from `$sourceIp at `$time"
        `$priority = "low"
        `$tags = "computer,logoff"
    }
    default {
        `$typeText = `$logonTypeMap[`$logonType]
        if (-not `$typeText) { `$typeText = "Type `$logonType" }

        `$title = "Hyper-V Host Login Alert"
        `$body = "Login on `$computer by `$user (`$typeText) from `$sourceIp at `$time"
        `$priority = "high"
        `$tags = "server,warning"
    }
}

`$headers = @{
    "Title" = `$title
    "Priority" = `$priority
    "Tags" = `$tags
}

$(if ($authHeaderLine) { "`$headers[" + '"Authorization"' + "] = `"Bearer " + $NtfyAccessToken + "`"`n" } else { "" })
try {
    Invoke-RestMethod -Uri "$uri" -Method Post -Body `$body -Headers `$headers -ErrorAction Stop
} catch {
    Write-Output "ntfy notification failed: `$_"
}
"@

# Write the script.
if ($PSCmdlet.ShouldProcess($scriptPath, "Create notification script")) {
    $scriptContent | Out-File -FilePath $scriptPath -Encoding UTF8
    Write-Success "Created $scriptPath"
}

# Register the scheduled task.
Write-Info "Registering scheduled task '$TaskName'..."
if ($PSCmdlet.ShouldProcess($TaskName, "Register scheduled task")) {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -File `"$scriptPath`""

    $CIMTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $trigger = New-CimInstance -CimClass $CIMTriggerClass -ClientOnly
    $trigger.Subscription = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">*[System[(EventID=4624 or EventID=4625 or EventID=4634 or EventID=4647)]]</Select>
  </Query>
</QueryList>
"@
    $trigger.Enabled = $true

    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Warn "Existing task '$TaskName' removed and recreated"
    }

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger -Principal $principal `
        -Description "Sends ntfy alert on logon, logoff, and failed logons" | Out-Null

    Write-Success "Registered scheduled task '$TaskName'"
}

# Test notification.
Write-Info "Sending test notification..."
$testHeaders = @{
    "Title" = "Hyper-V Logon Alert Test"
    "Priority" = "high"
    "Tags" = "server,test"
}
if ($NtfyAccessToken) {
    $testHeaders["Authorization"] = "Bearer $NtfyAccessToken"
}

try {
    Invoke-RestMethod -Uri $uri -Method Post `
        -Body "ntfy logon alerts configured on `$env:COMPUTERNAME" `
        -Headers $testHeaders -ErrorAction Stop | Out-Null
    Write-Success "Test notification sent successfully"
} catch {
    Write-Warn "Test notification failed: $_"
}

Write-Success "Installation complete. Task: $TaskName, Script: $scriptPath"
