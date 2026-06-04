<#
.SYNOPSIS
    Chocolatey installation script for PatchStateAgent.
.DESCRIPTION
    1. Creates C:\ProgramData\PatchStateAgent\ directory hierarchy.
    2. Deploys PatchStateAgent.ps1 to the install directory.
    3. Writes configuration to HKLM:\SOFTWARE\PatchStateAgent\Config\.
    4. Registers a Windows Scheduled Task running daily as NT AUTHORITY\SYSTEM.
    5. Registers the Event Log source for PatchStateAgent.

.PARAMETER (via Chocolatey package parameters)
    /ServerTag:<string>   - Server classification tag (e.g. Web, SQL, DMZ)
    /SmbPath:<string>     - Target UNC path for report delivery
    /SmtpServer:<string>  - SMTP relay server for fallback delivery
    /SmtpTo:<string>      - Recipient address for SMTP fallback (e.g. reports@corp.local)
    /SmtpFrom:<string>    - Sender address (optional, defaults to psa@<hostname>.local)
    /SmtpPort:<int>       - SMTP port (optional, defaults to 25)
    /HistoryLimit:<int>   - Maximum number of historical runs to retain in logs (optional, defaults to 30)
    /MaxDisplayChanges:<int> - Default number of changes to display in dashboard (optional, defaults to 50)

.EXAMPLE
    choco install patchstateagent --params "/ServerTag:SQL /SmbPath:\\fileserver\reports /SmtpServer:smtp.corp.local /SmtpTo:ops@corp.local"
#>

$packageName = 'patchstateagent'
$toolsDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition

# --- Paths ---
$InstallDir     = Join-Path $env:ProgramData 'PatchStateAgent'
$LogsDir        = Join-Path $InstallDir 'Logs'
$StateDir       = Join-Path $InstallDir 'State'
$UndeliveredDir = Join-Path $InstallDir 'undelivered'
$AgentScript    = Join-Path $toolsDir 'PatchStateAgent.ps1'
$AgentDest      = Join-Path $InstallDir 'PatchStateAgent.ps1'

# Registry paths
$RegRoot   = 'HKLM:\SOFTWARE\PatchStateAgent'
$RegConfig = 'HKLM:\SOFTWARE\PatchStateAgent\Config'

$TaskName  = 'PatchStateAgent-Daily'

# --- Parse Chocolatey package parameters ---
$PackageParams = Get-PackageParameters

$ServerTag  = if ($PackageParams['ServerTag'])  { $PackageParams['ServerTag']  } else { 'Untagged' }
$SmbPath    = if ($PackageParams['SmbPath'])    { $PackageParams['SmbPath']    } else { '' }
$SmtpServer = if ($PackageParams['SmtpServer']) { $PackageParams['SmtpServer'] } else { '' }
$SmtpTo     = if ($PackageParams['SmtpTo'])     { $PackageParams['SmtpTo']     } else { '' }
$SmtpFrom   = if ($PackageParams['SmtpFrom'])   { $PackageParams['SmtpFrom']   } else { '' }
$SmtpPort   = if ($PackageParams['SmtpPort'])   { [int]$PackageParams['SmtpPort'] } else { 25 }
$HistoryLimit  = if ($PackageParams['HistoryLimit']) { [int]$PackageParams['HistoryLimit'] } else { 30 }
$MaxDisplayChanges = if ($PackageParams['MaxDisplayChanges']) { [int]$PackageParams['MaxDisplayChanges'] } else { 50 }

Write-Host "[$packageName] Installing PatchStateAgent..."

# --- Step 1: Create Directory Hierarchy ---
foreach ($Dir in @($InstallDir, $LogsDir, $StateDir, $UndeliveredDir)) {
    if (-not (Test-Path $Dir)) {
        $null = New-Item -Path $Dir -ItemType Directory -Force
        Write-Host "[$packageName] Created: $Dir"
    }
}

# --- Step 2: Deploy Agent Script ---
if (Test-Path $AgentScript) {
    Copy-Item -Path $AgentScript -Destination $AgentDest -Force
    Write-Host "[$packageName] Deployed agent script to: $AgentDest"
}
else {
    throw "[$packageName] Source script not found at '$AgentScript'. Package may be malformed."
}

# --- Step 3: Write Registry Configuration ---
# Ensure root key exists
if (-not (Test-Path $RegRoot)) {
    $null = New-Item -Path $RegRoot -Force
}
if (-not (Test-Path $RegConfig)) {
    $null = New-Item -Path $RegConfig -Force
}

# Write config values (idempotent - update on re-install)
$ConfigValues = @{
    ServerTag         = $ServerTag
    SmbPath           = $SmbPath
    SmtpServer        = $SmtpServer
    SmtpTo            = $SmtpTo
    SmtpFrom          = $SmtpFrom
    SmtpPort          = $SmtpPort
    HistoryLimit      = $HistoryLimit
    MaxDisplayChanges = $MaxDisplayChanges
}

foreach ($Key in $ConfigValues.Keys) {
    $Type  = if ($Key -eq 'SmtpPort' -or $Key -eq 'HistoryLimit' -or $Key -eq 'MaxDisplayChanges') { 'DWord' } else { 'String' }
    Set-ItemProperty -Path $RegConfig -Name $Key -Value $ConfigValues[$Key] -Type $Type -Force
}

# Initialise orchestrator semaphore to 0 (not triggered) only if missing
$ExistingFlag = Get-ItemProperty -Path $RegRoot -Name 'OrchestratorTriggered' -ErrorAction SilentlyContinue
if ($null -eq $ExistingFlag) {
    Set-ItemProperty -Path $RegRoot -Name 'OrchestratorTriggered' -Value 0 -Type DWord -Force
}

Write-Host "[$packageName] Registry configuration written."

# --- Step 4: Register Event Log Source (requires elevation) ---
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists('PatchStateAgent')) {
        [System.Diagnostics.EventLog]::CreateEventSource('PatchStateAgent', 'Application')
        Write-Host "[$packageName] Event Log source 'PatchStateAgent' registered."
    }
}
catch {
    Write-Warning "[$packageName] Could not register Event Log source (non-fatal): $_"
}

# --- Step 5: Register Scheduled Task (idempotent) ---
# Remove existing task if present (avoids duplicate registration on re-install)
$ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($ExistingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[$packageName] Removed existing scheduled task for re-registration."
}

$Action  = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$AgentDest`""

$Trigger = New-ScheduledTaskTrigger -Daily -At '06:00AM'

$Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 30) `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

$Principal = New-ScheduledTaskPrincipal `
    -UserId 'NT AUTHORITY\SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName  $TaskName `
    -Action    $Action `
    -Trigger   $Trigger `
    -Settings  $Settings `
    -Principal $Principal `
    -Description 'PatchStateAgent daily patch state capture and reporting.' `
    -Force

Write-Host "[$packageName] Scheduled task '$TaskName' registered (daily at 06:00, runs as SYSTEM)."
Write-Host "[$packageName] Installation complete."
