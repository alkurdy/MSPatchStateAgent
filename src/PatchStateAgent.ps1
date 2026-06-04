<#
.SYNOPSIS
    PatchStateAgent (PSA) - Windows patch state capture and reporting agent.
.DESCRIPTION
    Captures installed Windows hotfix states, computes a diff against the previous
    run, and exports a structured JSON report via SMB -> SMTP -> Local Cache fallback.

    Designed following spacecraft / high-SLA principles:
      - Zero external dependencies (PowerShell 5.1+ native only)
      - Atomic writes (write-to-temp-then-rename) prevent state file corruption
      - Bounded timeouts on all OS calls prevent indefinite hang
      - Self-healing: all required directories are auto-provisioned on every run
      - Defensive registry reads always fall back to safe defaults
      - Log rotation prevents disk exhaustion

.PARAMETER SimulateSmbFailure
    Forces the SMB upload to fail so the SMTP fallback path can be validated.
.PARAMETER SimulateSmtpFailure
    Forces the SMTP step to fail so the Local Cache fallback path can be validated.
.NOTES
    Requires elevation (Administrator) only for first-time Event Log source creation.
    Routine runs as NT AUTHORITY\SYSTEM via the registered Scheduled Task.
.LINK
    SPEC.md
#>
[CmdletBinding()]
param (
    [switch]$SimulateSmbFailure,
    [switch]$SimulateSmtpFailure,
    [switch]$BypassOrchestratorCheck,
    [int]$HistoryLimit,
    [int]$MaxDisplayChanges
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Constants & Path Definitions ---

$Script:AgentName      = 'PatchStateAgent'
$Script:EventLogSource = 'PatchStateAgent'
$Script:EventLogName   = 'Application'

# Registry paths
$Script:RegRoot      = 'HKLM:\SOFTWARE\PatchStateAgent'
$Script:RegConfig    = 'HKLM:\SOFTWARE\PatchStateAgent\Config'

# Filesystem paths (all paths under ProgramData - writable by SYSTEM without elevation)
$Script:ProgramDataRoot = Join-Path $env:ProgramData $Script:AgentName
$Script:LogsDir         = Join-Path $Script:ProgramDataRoot 'Logs'
$Script:StateDir        = Join-Path $Script:ProgramDataRoot 'State'
$Script:UndeliveredDir  = Join-Path $Script:ProgramDataRoot 'undelivered'

$Script:LogFile           = Join-Path $Script:LogsDir  'agent.log'
$Script:CurrentStateFile  = Join-Path $Script:StateDir 'current_state.json'
$Script:PreviousStateFile = Join-Path $Script:StateDir 'previous_state.json'

# Operational constants
$Script:MaxLogSizeBytes  = 5MB        # Log rolls over at 5 MB
$Script:HotFixTimeoutSec = 60         # Max time to wait for Get-HotFix via job
$Script:SmbTimeoutSec    = 30         # Max time for SMB write attempt via job

#endregion

#region --- Write-AgentLog ---

function Write-AgentLog {
    <#
    .SYNOPSIS
        Writes a standardised, timestamped log entry to file and Event Viewer.
    .DESCRIPTION
        Format: [YYYY-MM-DD HH:mm:ss] [LEVEL] Message
        Log file is rotated (renamed to agent.log.old) when it exceeds MaxLogSizeBytes.
        Event Viewer failures are silently swallowed so logging never blocks the agent.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $Entry     = "[$Timestamp] [$Level] $Message"

    # --- File logging with rotation ---
    try {
        # Self-heal: ensure directory exists
        if (-not (Test-PathExists -Path $Script:LogsDir)) {
            $null = New-Directory -Path $Script:LogsDir
        }

        # Rotate if log exceeds size limit
        if (Test-PathExists -Path $Script:LogFile) {
            $LogItem = Get-Item -Path $Script:LogFile -ErrorAction SilentlyContinue
            if ($LogItem -and $LogItem.Length -gt $Script:MaxLogSizeBytes) {
                $OldLog = Join-Path $Script:LogsDir "agent.log.old"
                Move-Item -Path $Script:LogFile -Destination $OldLog -Force -ErrorAction SilentlyContinue
            }
        }

        Add-Content -Path $Script:LogFile -Value $Entry -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # File logging failed - write to console and continue; do not abort the agent
        Write-Warning "Log file write failed: $_"
    }

    # --- Event Viewer logging ---
    try {
        # Map agent log level to EventType
        $EvtType = switch ($Level) {
            'INFO'  { 'Information' }
            'WARN'  { 'Warning' }
            'ERROR' { 'Error' }
        }

        # Ensure event source exists (requires elevation; installer does this, but guard anyway)
        if (-not [System.Diagnostics.EventLog]::SourceExists($Script:EventLogSource)) {
            [System.Diagnostics.EventLog]::CreateEventSource($Script:EventLogSource, $Script:EventLogName)
        }

        Write-EventLog -LogName $Script:EventLogName `
                       -Source  $Script:EventLogSource `
                       -EventId 1000 `
                       -EntryType $EvtType `
                       -Message $Message `
                       -ErrorAction Stop
    }
    catch {
        # Event log write is best-effort; never block on it
    }
}

#endregion

#region --- Low-Level OS Abstraction (Wrapper Helpers) ---

function Test-PathExists {
    param([string]$Path)
    return Test-Path -Path $Path
}

function New-Directory {
    param([string]$Path)
    return New-Item -Path $Path -ItemType Directory -Force
}

function Get-RegistryValue {
    param([string]$Path, [string]$Name)
    $Prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $Prop) { return $Prop.$Name }
    return $null
}

function Set-RegistryValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'String')
    if (-not (Test-Path -Path $Path)) {
        $null = New-Item -Path $Path -Force
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Get-SystemMetrics {
    <#
    .SYNOPSIS
        Queries operating system and hardware resource metrics natively using CIM.
    .OUTPUTS
        [hashtable] A dictionary containing OS, CPU, RAM, and Storage info.
    #>
    [CmdletBinding()]
    param ()

    try {
        $Os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $Cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $Drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop

        $TotalRamGb = [Math]::Round($Os.TotalVisibleMemorySize / 1MB, 1)
        $FreeRamGb = [Math]::Round($Os.FreePhysicalMemory / 1MB, 1)
        $UsedRamGb = [Math]::Round($TotalRamGb - $FreeRamGb, 1)

        $StorageTotalGb = [Math]::Round($Drive.Size / 1GB, 1)
        $StorageFreeGb = [Math]::Round($Drive.FreeSpace / 1GB, 1)
        $StorageUsedGb = [Math]::Round(($Drive.Size - $Drive.FreeSpace) / 1GB, 1)
        $StoragePct = if ($StorageTotalGb -gt 0) { [Math]::Round(($StorageUsedGb / $StorageTotalGb) * 100, 1) } else { 0 }

        return @{
            os_name        = $Os.Caption
            os_version     = $Os.Version
            os_build       = $Os.BuildNumber
            cpu_name       = $Cpu.Name.Trim()
            cpu_cores      = $Cpu.NumberOfLogicalProcessors
            ram_total_gb   = $TotalRamGb
            ram_used_gb    = $UsedRamGb
            storage_total  = $StorageTotalGb
            storage_used   = $StorageUsedGb
            storage_pct    = $StoragePct
        }
    }
    catch {
        Write-AgentLog -Level 'WARN' -Message "Failed to capture system metrics: $_"
        return $null
    }
}

#endregion

#region --- Initialize-Environment ---

function Initialize-Environment {
    <#
    .SYNOPSIS
        Ensures all required directories exist. Self-heals silently on every run.
    .DESCRIPTION
        Spacecraft principle: the agent provisions its own infrastructure rather than
        assuming it was left intact. This survives disk cleanups, re-imaging mistakes,
        and partial uninstalls.
    #>
    [CmdletBinding()]
    param ()

    $RequiredPaths = @(
        $Script:ProgramDataRoot,
        $Script:LogsDir,
        $Script:StateDir,
        $Script:UndeliveredDir
    )

    foreach ($Path in $RequiredPaths) {
        if (-not (Test-PathExists -Path $Path)) {
            try {
                $null = New-Directory -Path $Path -ErrorAction Stop
                Write-AgentLog -Level 'INFO' -Message "Provisioned missing directory: $Path"
            }
            catch {
                # Log and continue - some dirs may be non-critical
                Write-AgentLog -Level 'WARN' -Message "Could not create directory '$Path': $_"
            }
        }
    }
}

#endregion

#region --- Get-RegistryConfig ---

function Get-RegistryConfig {
    <#
    .SYNOPSIS
        Safely reads a value from the agent's registry configuration key.
    .DESCRIPTION
        Falls back to $DefaultValue on any error so the agent never aborts due to
        a missing or corrupt registry key.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ValueName,

        $DefaultValue = $null
    )

    try {
        $Val = Get-RegistryValue -Path $Script:RegConfig -Name $ValueName
        if ($null -ne $Val) { return $Val }
    }
    catch {
        Write-AgentLog -Level 'WARN' -Message "Registry read failed for '$ValueName', using default. Error: $_"
    }

    return $DefaultValue
}

#endregion

#region --- Test-OrchestratorOverride ---

function Test-OrchestratorOverride {
    <#
    .SYNOPSIS
        Checks the Windmill orchestrator semaphore flag.
    .DESCRIPTION
        Reads HKLM:\SOFTWARE\PatchStateAgent\OrchestratorTriggered (REG_DWORD).
        If the value is 1, resets it to 0, logs the bypass, and returns $true
        to signal the caller to exit cleanly.
    .OUTPUTS
        [bool] $true if execution should be skipped, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    try {
        if (-not (Test-PathExists -Path $Script:RegRoot)) {
            return $false
        }

        $Val = Get-RegistryValue -Path $Script:RegRoot -Name 'OrchestratorTriggered'

        if ($null -ne $Val -and $Val -eq 1) {
            # Reset flag immediately (before any other work) to prevent permanent lockout
            Set-RegistryValue -Path $Script:RegRoot -Name 'OrchestratorTriggered' -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Write-AgentLog -Level 'WARN' -Message 'Orchestrator override flag detected. Skipping this execution cycle. Flag reset to 0.'
            return $true
        }
    }
    catch {
        Write-AgentLog -Level 'ERROR' -Message "Registry access error during orchestrator check: $_"
    }

    return $false
}

#endregion

#region --- Get-PatchState ---

function Get-PatchState {
    <#
    .SYNOPSIS
        Retrieves installed hotfixes and returns a clean, sorted array.
    .DESCRIPTION
        Wraps Get-HotFix in a background Job with a hard timeout to avoid indefinite
        WMI/CIM hangs (spacecraft rule: all blocking calls must be bounded).
        Returns an empty array on timeout or error so downstream code still runs.
    .OUTPUTS
        [array] Array of objects with HotFixID and InstalledOn properties.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param ()

    Write-AgentLog -Level 'INFO' -Message 'Capturing current patch state via Get-HotFix...'

    $Job = Start-Job -ScriptBlock { Get-HotFix -ErrorAction SilentlyContinue }

    try {
        $Completed = Wait-Job -Job $Job -Timeout $Script:HotFixTimeoutSec

        if ($null -eq $Completed) {
            # Timed out - kill the job and return empty
            Stop-Job  -Job $Job -ErrorAction SilentlyContinue
            Write-AgentLog -Level 'ERROR' -Message "Get-HotFix timed out after $($Script:HotFixTimeoutSec)s. WMI/CIM may be unresponsive."
            return , @()
        }

        $RawHotFixes = Receive-Job -Job $Job -ErrorAction SilentlyContinue

        if (-not $RawHotFixes) {
            Write-AgentLog -Level 'WARN' -Message 'Get-HotFix returned no results.'
            return , @()
        }

        # Extract only the fields we care about; normalise InstalledOn to ISO date string
        $CleanHotFixes = $RawHotFixes | ForEach-Object {
            $InstalledOn = $null
            if ($_.InstalledOn) {
                try { $InstalledOn = ([datetime]$_.InstalledOn).ToString('yyyy-MM-dd') } catch { }
            }
            [PSCustomObject]@{
                kb_id        = $_.HotFixID
                installed_on = $InstalledOn
            }
        } | Sort-Object kb_id

        Write-AgentLog -Level 'INFO' -Message "Captured $($CleanHotFixes.Count) hotfix entries."
        return $CleanHotFixes
    }
    finally {
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region --- Read-StateFile / Write-StateFile (Atomic) ---

function Read-StateFile {
    <#
    .SYNOPSIS
        Reads and parses a JSON state file defensively.
    .DESCRIPTION
        If the file is missing or the JSON is corrupt, logs a warning, archives the
        corrupt file (so it can be inspected later), and returns an empty array.
        Spacecraft principle: never let a corrupt input kill the agent.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    if (-not (Test-Path -Path $FilePath)) {
        return , @()
    }

    try {
        $RawJson = Get-Content -Raw -Path $FilePath -ErrorAction Stop
        $Parsed  = ConvertFrom-Json -InputObject $RawJson -ErrorAction Stop
        return , @($Parsed)
    }
    catch {
        # Archive corrupt file so a human can inspect it later
        $ArchiveName = "$FilePath.corrupt.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Rename-Item -Path $FilePath -NewName $ArchiveName -Force -ErrorAction SilentlyContinue
        Write-AgentLog -Level 'WARN' -Message "State file '$FilePath' was corrupt and has been archived as '$ArchiveName'. Starting fresh."
        return , @()
    }
}

function Write-StateFile {
    <#
    .SYNOPSIS
        Atomically writes an object as a JSON state file.
    .DESCRIPTION
        Uses write-to-temp-then-rename so the file is never left in a partial/corrupt
        state if the system loses power or the process is killed mid-write.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        $Data
    )

    $TempFile = "$FilePath.tmp"

    try {
        $Json = ConvertTo-Json -InputObject $Data -Depth 10 -Compress:$false -ErrorAction Stop
        $Json | Out-File -FilePath $TempFile -Encoding UTF8 -Force -ErrorAction Stop
        Move-Item   -Path $TempFile -Destination $FilePath -Force -ErrorAction Stop
    }
    catch {
        Write-AgentLog -Level 'ERROR' -Message "Atomic state write failed for '$FilePath': $_"
        # Clean up temp file if it was created
        if (Test-PathExists -Path $TempFile) { Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue }
    }
}

#endregion

#region --- Compare-PatchState ---

function Compare-PatchState {
    <#
    .SYNOPSIS
        Computes a diff between the current and previous hotfix arrays.
    .DESCRIPTION
        Returns a structured patch report object suitable for JSON export and
        downstream reporting/API consumption as defined in the spec.
    .OUTPUTS
        [PSCustomObject] Report payload with timestamp, summary, and diff list.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$CurrentState,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$PreviousState
    )

    # Build lookup sets for O(n) comparison
    $PreviousKbs = @{}
    foreach ($Patch in $PreviousState) {
        if ($Patch.kb_id) { $PreviousKbs[$Patch.kb_id] = $Patch }
    }

    $CurrentKbs = @{}
    foreach ($Patch in $CurrentState) {
        if ($Patch.kb_id) { $CurrentKbs[$Patch.kb_id] = $Patch }
    }

    $DiffList = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Detect added patches (present in current, not in previous)
    foreach ($KbId in $CurrentKbs.Keys) {
        if (-not $PreviousKbs.ContainsKey($KbId)) {
            $DiffList.Add([PSCustomObject]@{
                kb_id        = $KbId
                action       = 'added'
                installed_on = $CurrentKbs[$KbId].installed_on
            })
        }
    }

    # Detect removed patches (present in previous, not in current)
    foreach ($KbId in $PreviousKbs.Keys) {
        if (-not $CurrentKbs.ContainsKey($KbId)) {
            $DiffList.Add([PSCustomObject]@{
                kb_id        = $KbId
                action       = 'removed'
                installed_on = $PreviousKbs[$KbId].installed_on
            })
        }
    }

    $Report = [PSCustomObject]@{
        timestamp             = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
        computer_name         = $env:COMPUTERNAME
        tag                   = (Get-RegistryConfig -ValueName 'ServerTag' -DefaultValue 'Untagged')
        orchestrator_override = $false
        destinations          = [PSCustomObject]@{
            smb   = (Get-RegistryConfig -ValueName 'SmbPath' -DefaultValue 'Not Configured')
            smtp  = if (Get-RegistryConfig -ValueName 'SmtpServer') { 
                        "$((Get-RegistryConfig -ValueName 'SmtpServer')) (to: $((Get-RegistryConfig -ValueName 'SmtpTo')))" 
                    } else { 
                        'Not Configured' 
                    }
            local = $Script:StateDir
        }
        summary               = [PSCustomObject]@{
            added   = @($DiffList | Where-Object { $_.action -eq 'added' }).Count
            removed = @($DiffList | Where-Object { $_.action -eq 'removed' }).Count
            total   = @($CurrentState).Count
        }
        diff                  = $DiffList.ToArray()
    }

    Write-AgentLog -Level 'INFO' -Message "Diff complete. Added: $($Report.summary.added), Removed: $($Report.summary.removed), Total: $($Report.summary.total)"
    return $Report
}

#endregion

#region --- Send-PatchReport (Cascading Transport Layer) ---

function Invoke-SmbUpload {
    <#
    .SYNOPSIS
        Attempts to write the report files to the configured SMB share.
    .DESCRIPTION
        Uses a Job with a bounded timeout to prevent indefinite network hangs.
    .OUTPUTS
        [bool] $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$JsonFilePath,

        [Parameter(Mandatory)]
        [string]$HtmlFilePath
    )

    $SmbPath = Get-RegistryConfig -ValueName 'SmbPath' -DefaultValue ''
    $Tag     = Get-RegistryConfig -ValueName 'ServerTag' -DefaultValue 'Untagged'

    if ([string]::IsNullOrWhiteSpace($SmbPath)) {
        Write-AgentLog -Level 'WARN' -Message 'SMB upload skipped: no SmbPath configured.'
        return $false
    }

    # Build per-tag, per-host directory
    $TargetDir  = Join-Path $SmbPath (Join-Path $Tag $env:COMPUTERNAME)
    $TargetJson = Join-Path $TargetDir "$($env:COMPUTERNAME)-report.json"
    $TargetHtml = Join-Path $TargetDir "$($env:COMPUTERNAME)-dashboard.html"

    Write-AgentLog -Level 'INFO' -Message "Attempting SMB upload to: $TargetDir"

    # Run inside a bounded job to prevent indefinite network hang
    $Job = Start-Job -ScriptBlock {
        param ($JsonFilePath, $HtmlFilePath, $TargetDir, $TargetJson, $TargetHtml)
        if (-not (Test-Path $TargetDir)) {
            $null = New-Item -Path $TargetDir -ItemType Directory -Force -ErrorAction Stop
        }
        Copy-Item -Path $JsonFilePath -Destination $TargetJson -Force -ErrorAction Stop
        Copy-Item -Path $HtmlFilePath -Destination $TargetHtml -Force -ErrorAction Stop
    } -ArgumentList $JsonFilePath, $HtmlFilePath, $TargetDir, $TargetJson, $TargetHtml

    try {
        $Completed = Wait-Job -Job $Job -Timeout $Script:SmbTimeoutSec
        if ($null -eq $Completed) {
            Stop-Job -Job $Job -ErrorAction SilentlyContinue
            Write-AgentLog -Level 'WARN' -Message "SMB upload timed out after $($Script:SmbTimeoutSec)s."
            return $false
        }

        $JobErrors = $Job.ChildJobs | Where-Object { $_.Error.Count -gt 0 }
        if ($JobErrors) {
            $ErrMsg = $JobErrors | ForEach-Object { $_.Error[0].ToString() } | Select-Object -First 1
            Write-AgentLog -Level 'WARN' -Message "SMB upload failed: $ErrMsg"
            return $false
        }

        Write-AgentLog -Level 'INFO' -Message 'SMB upload succeeded.'
        return $true
    }
    finally {
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SmtpDelivery {
    <#
    .SYNOPSIS
        Sends the report files as email attachments to the configured ingestion mailbox.
    .OUTPUTS
        [bool] $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$JsonFilePath,

        [Parameter(Mandatory)]
        [string]$HtmlFilePath
    )

    $SmtpServer = Get-RegistryConfig -ValueName 'SmtpServer'    -DefaultValue ''
    $SmtpFrom   = Get-RegistryConfig -ValueName 'SmtpFrom'      -DefaultValue "psa@$($env:COMPUTERNAME.ToLower()).local"
    $SmtpTo     = Get-RegistryConfig -ValueName 'SmtpTo'        -DefaultValue ''
    $SmtpPort   = Get-RegistryConfig -ValueName 'SmtpPort'      -DefaultValue 25

    if ([string]::IsNullOrWhiteSpace($SmtpServer) -or [string]::IsNullOrWhiteSpace($SmtpTo)) {
        Write-AgentLog -Level 'WARN' -Message 'SMTP delivery skipped: SmtpServer or SmtpTo not configured.'
        return $false
    }

    Write-AgentLog -Level 'INFO' -Message "Attempting SMTP delivery via $SmtpServer to $SmtpTo..."

    try {
        $MailParams = @{
            SmtpServer  = $SmtpServer
            Port        = [int]$SmtpPort
            From        = $SmtpFrom
            To          = $SmtpTo
            Subject     = "[$Script:AgentName] Patch History Report - $($env:COMPUTERNAME)"
            Body        = "PatchStateAgent report files attached (JSON and HTML). Computer: $($env:COMPUTERNAME)"
            Attachments = @($JsonFilePath, $HtmlFilePath)
            ErrorAction = 'Stop'
        }

        Send-MailMessage @MailParams
        Write-AgentLog -Level 'INFO' -Message 'SMTP delivery succeeded.'
        return $true
    }
    catch {
        Write-AgentLog -Level 'WARN' -Message "SMTP delivery failed: $_"
        return $false
    }
}

function Invoke-LocalCache {
    <#
    .SYNOPSIS
        Saves the report files to the local undelivered cache as a last resort.
    .OUTPUTS
        [bool] $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$JsonFilePath,

        [Parameter(Mandatory)]
        [string]$HtmlFilePath
    )

    Write-AgentLog -Level 'WARN' -Message 'All transport methods exhausted. Caching report locally.'

    try {
        $TargetJson = Join-Path $Script:UndeliveredDir "$($env:COMPUTERNAME)-report.json"
        $TargetHtml = Join-Path $Script:UndeliveredDir "$($env:COMPUTERNAME)-dashboard.html"

        Copy-Item -Path $JsonFilePath -Destination $TargetJson -Force -ErrorAction Stop
        Copy-Item -Path $HtmlFilePath -Destination $TargetHtml -Force -ErrorAction Stop

        Write-AgentLog -Level 'WARN' -Message "Report cached locally at: $TargetJson and $TargetHtml"
        return $true
    }
    catch {
        Write-AgentLog -Level 'ERROR' -Message "Local cache write also failed. Report data LOST: $_"
        return $false
    }
}

function Send-PatchReport {
    <#
    .SYNOPSIS
        Delivers the patch reports via cascading transport: SMB -> SMTP -> Local Cache.
    .DESCRIPTION
        Attempts each delivery method in priority order. Stops at the first success.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$JsonFilePath,

        [Parameter(Mandatory)]
        [string]$HtmlFilePath
    )

    # Priority 1: SMB (unless simulated failure is requested)
    if (-not $Script:SimulateSmbFailure) {
        if (Invoke-SmbUpload -JsonFilePath $JsonFilePath -HtmlFilePath $HtmlFilePath) { return }
    }
    else {
        Write-AgentLog -Level 'WARN' -Message 'SimulateSmbFailure is active - bypassing SMB upload.'
    }

    # Priority 2: SMTP (unless simulated failure is requested)
    if (-not $Script:SimulateSmtpFailure) {
        if (Invoke-SmtpDelivery -JsonFilePath $JsonFilePath -HtmlFilePath $HtmlFilePath) { return }
    }
    else {
        Write-AgentLog -Level 'WARN' -Message 'SimulateSmtpFailure is active - bypassing SMTP delivery.'
    }

    # Priority 3: Local Cache (last resort)
    $null = Invoke-LocalCache -JsonFilePath $JsonFilePath -HtmlFilePath $HtmlFilePath
}

#endregion

#region --- HTML Dashboard Compilation ---

function Export-PatchHtml {
    <#
    .SYNOPSIS
        Compiles the historical run data into a premium static HTML dashboard.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $HistoryData,

        [Parameter(Mandatory)]
        [string]$HtmlFilePath
    )

    $HistoryJson = ConvertTo-Json -InputObject $HistoryData -Depth 10 -Compress

    $HtmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PatchStateAgent Dashboard - $($HistoryData.computer_name)</title>
    <style>
        :root {
            --bg-color: #080c14;
            --panel-bg: #111827;
            --panel-border: rgba(255, 255, 255, 0.08);
            --text-primary: #f3f4f6;
            --text-secondary: #9ca3af;
            --color-added: #10b981;
            --color-removed: #f43f5e;
            --color-total: #3b82f6;
            --glow-added: rgba(16, 185, 129, 0.15);
            --glow-removed: rgba(244, 63, 94, 0.15);
            --glow-total: rgba(59, 130, 246, 0.15);
            --font-stack: 'Outfit', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            background-color: var(--bg-color);
            background-image: 
                radial-gradient(circle at 50% 0%, #1e1b4b 0%, transparent 60%),
                radial-gradient(circle at 0% 100%, #0f172a 0%, transparent 60%);
            background-attachment: fixed;
            color: var(--text-primary);
            font-family: var(--font-stack);
            min-height: 100vh;
            display: flex;
            overflow: hidden;
        }

        /* Sidebar Styling */
        .sidebar {
            width: 320px;
            background-color: var(--panel-bg);
            border-right: 1px solid var(--panel-border);
            display: flex;
            flex-direction: column;
            flex-shrink: 0;
        }

        .sidebar-header {
            padding: 1.5rem;
            border-bottom: 1px solid var(--panel-border);
        }

        .sidebar-header h2 {
            font-size: 1.25rem;
            font-weight: 700;
            background: linear-gradient(to right, #3b82f6, #8b5cf6);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }

        .sidebar-header p {
            font-size: 0.75rem;
            color: var(--text-secondary);
            margin-top: 0.25rem;
        }

        .run-list {
            flex: 1;
            overflow-y: auto;
            padding: 0.75rem;
            display: flex;
            flex-direction: column;
            gap: 0.5rem;
        }

        .run-item {
            padding: 1rem;
            border-radius: 12px;
            cursor: pointer;
            border: 1px solid transparent;
            background: rgba(255, 255, 255, 0.01);
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
        }

        .run-item:hover {
            background: rgba(255, 255, 255, 0.04);
            border-color: rgba(255, 255, 255, 0.04);
        }

        .run-item.active {
            background: rgba(59, 130, 246, 0.08);
            border-color: rgba(59, 130, 246, 0.3);
            box-shadow: 0 4px 12px rgba(59, 130, 246, 0.08);
        }

        .run-date {
            font-size: 0.875rem;
            font-weight: 600;
            color: var(--text-primary);
        }

        .run-meta {
            font-size: 0.75rem;
            color: var(--text-secondary);
            margin-top: 0.375rem;
            display: flex;
            gap: 0.75rem;
        }

        .badge-count {
            display: inline-flex;
            align-items: center;
            gap: 0.25rem;
            font-weight: 700;
        }

        .badge-count.added { color: var(--color-added); }
        .badge-count.removed { color: var(--color-removed); }

        /* Main Content Viewport */
        .main-content {
            flex: 1;
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }

        .content-header {
            padding: 1.5rem 2rem;
            border-bottom: 1px solid var(--panel-border);
            display: flex;
            justify-content: space-between;
            align-items: center;
            background-color: rgba(17, 24, 39, 0.4);
            backdrop-filter: blur(8px);
        }

        .header-meta h1 {
            font-size: 1.5rem;
            font-weight: 700;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }

        .header-meta p {
            font-size: 0.875rem;
            color: var(--text-secondary);
            margin-top: 0.25rem;
        }

        .badge-tag {
            background: rgba(139, 92, 246, 0.12);
            color: #c084fc;
            border: 1px solid rgba(139, 92, 246, 0.25);
            padding: 0.25rem 0.75rem;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-weight: 700;
            letter-spacing: 0.05em;
            text-transform: uppercase;
        }

        /* Metrics Cards */
        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 1.5rem;
            padding: 2rem 2rem 1rem 2rem;
        }

        .metric-card {
            background: rgba(17, 24, 39, 0.6);
            border: 1px solid var(--panel-border);
            border-radius: 16px;
            padding: 1.25rem 1.5rem;
            display: flex;
            flex-direction: column;
            position: relative;
            overflow: hidden;
            transition: all 0.3s;
        }

        .metric-card:hover {
            transform: translateY(-2px);
            border-color: rgba(255, 255, 255, 0.12);
        }

        .metric-card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 3px;
        }

        .metric-card.added::before { background: var(--color-added); }
        .metric-card.removed::before { background: var(--color-removed); }
        .metric-card.total::before { background: var(--color-total); }

        .metric-card.added:hover { box-shadow: 0 8px 24px var(--glow-added); }
        .metric-card.removed:hover { box-shadow: 0 8px 24px var(--glow-removed); }
        .metric-card.total:hover { box-shadow: 0 8px 24px var(--glow-total); }

        .metric-label {
            font-size: 0.875rem;
            color: var(--text-secondary);
            text-transform: uppercase;
            font-weight: 600;
            letter-spacing: 0.05em;
        }

        .metric-value {
            font-size: 2.25rem;
            font-weight: 800;
            margin-top: 0.5rem;
        }

        .metric-card.added .metric-value { color: var(--color-added); }
        .metric-card.removed .metric-value { color: var(--color-removed); }
        .metric-card.total .metric-value { color: var(--color-total); }

        .resources-panel {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
            gap: 1.5rem;
            padding: 0 2rem 1.5rem 2rem;
        }

        .resource-card {
            background: rgba(17, 24, 39, 0.6);
            border: 1px solid var(--panel-border);
            border-radius: 16px;
            padding: 1.25rem 1.5rem;
            display: flex;
            flex-direction: column;
            justify-content: center;
        }

        .resource-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 0.5rem;
        }

        .resource-header h3 {
            font-size: 0.875rem;
            color: var(--text-secondary);
            text-transform: uppercase;
            font-weight: 600;
            letter-spacing: 0.05em;
        }

        .resource-value {
            font-size: 0.875rem;
            font-weight: 700;
            color: var(--text-primary);
        }

        .resource-text {
            font-size: 1rem;
            font-weight: 600;
            color: var(--text-primary);
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        .resource-subtext {
            font-size: 0.75rem;
            color: var(--text-secondary);
            margin-top: 0.25rem;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        .progress-bar-bg {
            background: rgba(255, 255, 255, 0.05);
            height: 8px;
            border-radius: 999px;
            overflow: hidden;
            border: 1px solid rgba(255, 255, 255, 0.04);
            margin-top: 0.25rem;
        }

        .progress-bar-fill {
            height: 100%;
            border-radius: 999px;
            width: 0%;
            transition: width 0.6s cubic-bezier(0.4, 0, 0.2, 1);
        }

        .ram-fill { background: linear-gradient(to right, #3b82f6, #8b5cf6); }
        .storage-fill { background: linear-gradient(to right, #eab308, #f97316); }

        /* Table & Filters Section */
        .table-section {
            flex: 1;
            overflow-y: auto;
            padding: 0 2rem 2rem 2rem;
            display: flex;
            flex-direction: column;
        }

        .table-controls {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 1rem;
        }

        .search-container {
            position: relative;
            width: 320px;
        }

        .search-input {
            width: 100%;
            background: rgba(255, 255, 255, 0.05);
            border: 1px solid var(--panel-border);
            border-radius: 10px;
            padding: 0.625rem 1rem 0.625rem 2.25rem;
            color: var(--text-primary);
            font-family: inherit;
            font-size: 0.875rem;
            transition: all 0.2s;
        }

        .search-input:focus {
            outline: none;
            border-color: #3b82f6;
            background: rgba(255, 255, 255, 0.08);
            box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.15);
        }

        .search-icon {
            position: absolute;
            left: 0.75rem;
            top: 50%;
            transform: translateY(-50%);
            color: var(--text-secondary);
            pointer-events: none;
            width: 16px;
            height: 16px;
        }

        .filter-tabs {
            display: flex;
            background: rgba(255, 255, 255, 0.04);
            padding: 0.25rem;
            border-radius: 10px;
            border: 1px solid var(--panel-border);
        }

        .filter-tab {
            background: transparent;
            border: none;
            color: var(--text-secondary);
            padding: 0.5rem 1.25rem;
            border-radius: 8px;
            cursor: pointer;
            font-family: inherit;
            font-size: 0.875rem;
            font-weight: 600;
            transition: all 0.2s;
        }

        .filter-tab:hover {
            color: var(--text-primary);
        }

        .filter-tab.active {
            background: rgba(255, 255, 255, 0.08);
            color: var(--text-primary);
        }

        .table-container {
            border: 1px solid var(--panel-border);
            border-radius: 12px;
            overflow: hidden;
            background-color: rgba(17, 24, 39, 0.4);
            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.2);
        }

        table {
            width: 100%;
            border-collapse: collapse;
            text-align: left;
        }

        th {
            background: rgba(255, 255, 255, 0.02);
            border-bottom: 1px solid var(--panel-border);
            color: var(--text-secondary);
            font-size: 0.75rem;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            padding: 1rem 1.5rem;
        }

        td {
            padding: 1rem 1.5rem;
            border-bottom: 1px solid var(--panel-border);
            font-size: 0.875rem;
            color: var(--text-primary);
        }

        tr:last-child td {
            border-bottom: none;
        }

        tr:hover td {
            background: rgba(255, 255, 255, 0.01);
        }

        .kb-cell {
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }

        .kb-link {
            color: #60a5fa;
            text-decoration: none;
            font-weight: 600;
            transition: color 0.2s;
        }

        .kb-link:hover {
            color: #93c5fd;
            text-decoration: underline;
        }

        .copy-btn {
            background: transparent;
            border: none;
            color: var(--text-secondary);
            cursor: pointer;
            padding: 0.25rem;
            border-radius: 4px;
            transition: all 0.2s;
            display: flex;
            align-items: center;
            justify-content: center;
        }

        .copy-btn:hover {
            color: var(--text-primary);
            background: rgba(255, 255, 255, 0.05);
        }

        .badge-action {
            display: inline-flex;
            align-items: center;
            gap: 0.375rem;
            padding: 0.25rem 0.625rem;
            border-radius: 6px;
            font-size: 0.75rem;
            font-weight: 700;
            text-transform: uppercase;
        }

        .badge-added {
            background: rgba(16, 185, 129, 0.12);
            color: #34d399;
            border: 1px solid rgba(16, 185, 129, 0.25);
        }

        .badge-removed {
            background: rgba(239, 68, 68, 0.12);
            color: #f87171;
            border: 1px solid rgba(239, 68, 68, 0.25);
        }

        .installed-date {
            color: var(--text-secondary);
            font-family: monospace;
        }

        .empty-state {
            padding: 4rem 2rem;
            text-align: center;
            color: var(--text-secondary);
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 0.75rem;
        }

        .empty-state h3 {
            color: var(--text-primary);
            font-size: 1.125rem;
            font-weight: 600;
        }

        /* Footer styling */
        footer {
            text-align: center;
            padding: 1rem 0;
            font-size: 0.75rem;
            color: var(--text-secondary);
            border-top: 1px solid var(--panel-border);
            margin-top: auto;
        }
    </style>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@400;600;700;800&display=swap" rel="stylesheet">
</head>
<body>
    <!-- Run History Sidebar -->
    <div class="sidebar">
        <div class="sidebar-header">
            <h2>PatchStateAgent</h2>
            <p>Historical Run List</p>
        </div>
        <!-- Overall Change Log button -->
        <div style="padding: 0.75rem 0.75rem 0 0.75rem;">
            <div id="overall-log-btn" class="run-item" onclick="selectOverallLog()" style="display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.25rem;">
                <svg style="width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:2" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
                </svg>
                <span style="font-weight: 700; font-size: 0.875rem;">Overall Change Log</span>
            </div>
        </div>
        <div style="border-bottom: 1px solid var(--panel-border); margin: 0.5rem 0.75rem;"></div>
        <div style="padding: 0 0.75rem 0.25rem 0.75rem; display: flex; justify-content: space-between; align-items: center;">
            <span style="font-size: 0.75rem; font-weight: 700; text-transform: uppercase; color: var(--text-secondary); letter-spacing: 0.05em;">Individual Runs</span>
            <label style="display: flex; align-items: center; gap: 0.25rem; font-size: 0.7rem; color: var(--text-secondary); cursor: pointer; user-select: none;">
                <input type="checkbox" id="hide-empty-check" onchange="toggleHideEmpty()" checked style="cursor: pointer; accent-color: #3b82f6;">
                Hide Empty
            </label>
        </div>
        <div class="run-list" id="run-list" style="padding-top: 0;">
            <!-- Dynamic Sidebar Items -->
        </div>
    </div>

    <!-- Main Panel -->
    <div class="main-content">
        <div class="content-header">
            <div class="header-meta">
                <h1 id="selected-host">$($HistoryData.computer_name)</h1>
                <p id="selected-time">Loading run details...</p>
            </div>
            <div style="display: flex; gap: 0.75rem; align-items: center;">
                <a id="json-link" href="#" target="_blank" class="badge-tag" style="background: rgba(59, 130, 246, 0.12); color: #60a5fa; border: 1px solid rgba(59, 130, 246, 0.25); text-decoration: none; display: flex; align-items: center; gap: 0.375rem; text-transform: none; letter-spacing: normal;">
                    <svg style="width:12px;height:12px;fill:none;stroke:currentColor;stroke-width:2.5" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m.75 12l3 3m0 0l3-3m-3 3v-6m-1.5-9H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z" />
                    </svg>
                    Raw JSON Report
                </a>
                <span class="badge-tag">$($HistoryData.tag)</span>
            </div>
        </div>

        <!-- Metrics cards -->
        <section class="metrics-grid">
            <div class="metric-card added">
                <span class="metric-label">Patches Added</span>
                <span class="metric-value" id="count-added">0</span>
            </div>
            <div class="metric-card removed">
                <span class="metric-label">Patches Removed</span>
                <span class="metric-value" id="count-removed">0</span>
            </div>
            <div class="metric-card total">
                <span class="metric-label">Total Active Patches</span>
                <span class="metric-value" id="count-total">0</span>
            </div>
        </section>

        <!-- System Resources Section -->
        <section class="resources-panel" id="resources-panel" style="display: none;">
            <div class="resource-card">
                <div class="resource-header">
                    <h3>Operating System</h3>
                </div>
                <div class="resource-body">
                    <p id="os-info" class="resource-text">-</p>
                    <p id="cpu-info" class="resource-subtext">-</p>
                </div>
            </div>
            <div class="resource-card">
                <div class="resource-header">
                    <h3>Memory (RAM)</h3>
                    <span id="ram-text" class="resource-value">-</span>
                </div>
                <div class="resource-body">
                    <div class="progress-bar-bg">
                        <div id="ram-bar" class="progress-bar-fill ram-fill" style="width: 0%;"></div>
                    </div>
                </div>
            </div>
            <div class="resource-card">
                <div class="resource-header">
                    <h3>Storage (C:)</h3>
                    <span id="storage-text" class="resource-value">-</span>
                </div>
                <div class="resource-body">
                    <div class="progress-bar-bg">
                        <div id="storage-bar" class="progress-bar-fill storage-fill" style="width: 0%;"></div>
                    </div>
                </div>
            </div>
            <div class="resource-card">
                <div class="resource-header">
                    <h3>Report Destinations</h3>
                </div>
                <div class="resource-body">
                    <p id="dest-smb" class="resource-subtext" style="margin-top: 0;">SMB: -</p>
                    <p id="dest-smtp" class="resource-subtext">SMTP: -</p>
                    <p id="dest-local" class="resource-subtext">Local: -</p>
                </div>
            </div>
        </section>

        <!-- Filters & Table Section -->
        <section class="table-section">
            <div class="table-controls">
                <div class="search-container">
                    <svg class="search-icon" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24" style="width:16px;height:16px;">
                        <path stroke-linecap="round" stroke-linejoin="round" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
                    </svg>
                    <input type="text" id="search-bar" class="search-input" placeholder="Search by KB ID...">
                </div>
                <div style="display: flex; gap: 0.75rem; align-items: center;">
                    <div style="display: flex; align-items: center; gap: 0.375rem; font-size: 0.875rem; color: var(--text-secondary);">
                        <span>Show:</span>
                        <select id="limit-select" onchange="changeDisplayLimit()" style="background: rgba(255, 255, 255, 0.05); border: 1px solid var(--panel-border); border-radius: 8px; color: var(--text-primary); padding: 0.375rem 0.5rem; outline: none; font-family: inherit; font-size: 0.875rem; cursor: pointer;">
                            <option value="10">10</option>
                            <option value="25">25</option>
                            <option value="50" selected>50</option>
                            <option value="100">100</option>
                            <option value="-1">All</option>
                        </select>
                    </div>
                    <div class="filter-tabs">
                        <button class="filter-tab active" data-filter="all">All Diffs</button>
                        <button class="filter-tab" data-filter="added">Added</button>
                        <button class="filter-tab" data-filter="removed">Removed</button>
                    </div>
                </div>
            </div>

            <div class="table-container">
                <table id="diff-table">
                    <thead>
                        <tr id="table-header-row">
                            <th style="width: 45%;">Hotfix / Knowledge Base</th>
                            <th style="width: 25%;">Action</th>
                            <th style="width: 30%;">Installation Date</th>
                        </tr>
                    </thead>
                    <tbody id="table-body">
                        <!-- Dynamic rows -->
                    </tbody>
                </table>
                <div id="empty-state" class="empty-state" style="display: none;">
                    <h3>No patch diffs found</h3>
                    <p>There are no additions or removals in this execution block, or search filters returned no matches.</p>
                </div>
                <div id="table-status" style="padding: 1rem 1.5rem; border-top: 1px solid var(--panel-border); font-size: 0.875rem; color: var(--text-secondary); text-align: center; display: none;">
                    <!-- Showing X of Y changes -->
                </div>
            </div>

            <footer>
                PatchStateAgent - System Integrity Monitoring - Local execution approved.
            </footer>
        </section>
    </div>

    <script>
        const historyData = $HistoryJson;

        const runListContainer = document.getElementById('run-list');
        const selectedTimeText = document.getElementById('selected-time');
        const countAddedText = document.getElementById('count-added');
        const countRemovedText = document.getElementById('count-removed');
        const countTotalText = document.getElementById('count-total');
        const tableBody = document.getElementById('table-body');
        const emptyState = document.getElementById('empty-state');
        const searchBar = document.getElementById('search-bar');
        const filterTabs = document.querySelectorAll('.filter-tab');
        
        // Resource elements
        const resourcesPanel = document.getElementById('resources-panel');
        const osInfoText = document.getElementById('os-info');
        const cpuInfoText = document.getElementById('cpu-info');
        const ramValueText = document.getElementById('ram-text');
        const ramBarFill = document.getElementById('ram-bar');
        const storageValueText = document.getElementById('storage-text');
        const storageBarFill = document.getElementById('storage-bar');

        let activeRunIndex = -1; // -1 represents Overall Change Log
        let currentFilter = 'all';
        let searchQuery = '';
        let hideEmpty = true;
        let displayLimit = historyData.max_display_changes || 50;

        // Initialize limit dropdown to configured value
        const limitSelect = document.getElementById('limit-select');
        if (limitSelect) {
            if ([10, 25, 50, 100].indexOf(displayLimit) !== -1) {
                limitSelect.value = displayLimit;
            } else if (displayLimit === -1) {
                limitSelect.value = "-1";
            } else {
                const opt = document.createElement('option');
                opt.value = displayLimit;
                opt.innerText = displayLimit;
                opt.selected = true;
                limitSelect.insertBefore(opt, limitSelect.firstChild);
            }
        }

        window.changeDisplayLimit = function() {
            const selectVal = document.getElementById('limit-select').value;
            displayLimit = parseInt(selectVal);
            if (activeRunIndex === -1) {
                renderOverallTableRows(getOverallLogDiffs());
            } else {
                const runs = historyData.history || [];
                const run = runs[activeRunIndex];
                if (run) {
                    renderTableRows(run.diff || []);
                }
            }
        }

        // Formats ISO timestamp to human readable local string
        function formatDate(isoString) {
            if (!isoString) return 'Unknown';
            try {
                const date = new Date(isoString);
                return date.toLocaleString(undefined, { 
                    dateStyle: 'medium', 
                    timeStyle: 'short' 
                });
            } catch(e) {
                return isoString;
            }
        }

        // Toggle visibility of empty runs
        window.toggleHideEmpty = function() {
            hideEmpty = document.getElementById('hide-empty-check').checked;
            renderSidebar();
        }

        // Render left sidebar list
        function renderSidebar() {
            const runs = historyData.history || [];
            
            // Render Overall Log button active state
            const overallBtn = document.getElementById('overall-log-btn');
            if (overallBtn) {
                if (activeRunIndex === -1) {
                    overallBtn.classList.add('active');
                } else {
                    overallBtn.classList.remove('active');
                }
            }

            if (runs.length === 0) {
                runListContainer.innerHTML = '<div style="padding:1rem;color:var(--text-secondary);text-align:center;font-size:0.875rem;">No historical data available</div>';
                return;
            }

            // Render from latest to oldest
            let html = '';
            for (let i = runs.length - 1; i >= 0; i--) {
                const run = runs[i];
                const isEmpty = (run.summary.added === 0 && run.summary.removed === 0);
                
                // Hide empty runs if checkbox checked, but always keep latest run (i === runs.length - 1)
                // so user can verify the script is executing successfully.
                if (hideEmpty && isEmpty && i !== runs.length - 1) {
                    continue;
                }

                const activeClass = i === activeRunIndex ? 'active' : '';
                html += '<div class="run-item ' + activeClass + '" onclick="selectRun(' + i + ')">' +
                            '<div class="run-date">' + formatDate(run.timestamp) + '</div>' +
                            '<div class="run-meta">' +
                                '<span class="badge-count added">+' + run.summary.added + '</span>' +
                                '<span class="badge-count removed">-' + run.summary.removed + '</span>' +
                                '<span>Total: ' + run.summary.total + '</span>' +
                            '</div>' +
                        '</div>';
            }
            runListContainer.innerHTML = html;
        }

        // Select Overall Log view
        window.selectOverallLog = function() {
            activeRunIndex = -1;
            renderSidebar();
            renderRunDetails(-1);
        }

        // Select a run from the sidebar
        window.selectRun = function(index) {
            activeRunIndex = index;
            renderSidebar();
            renderRunDetails(index);
        }

        // Compute overall diff list consolidated across all runs
        function getOverallLogDiffs() {
            const runs = historyData.history || [];
            const allDiffs = [];
            for (let i = 0; i < runs.length; i++) {
                const run = runs[i];
                const diffs = run.diff || [];
                for (let j = 0; j < diffs.length; j++) {
                    const item = diffs[j];
                    allDiffs.push({
                        kb_id: item.kb_id,
                        action: item.action,
                        installed_on: item.installed_on,
                        run_timestamp: run.timestamp
                    });
                }
            }
            // Sort by run timestamp descending so newest changes are first
            allDiffs.sort((a, b) => new Date(b.run_timestamp) - new Date(a.run_timestamp));
            return allDiffs;
        }

        // Render detail content area
        function renderRunDetails(index) {
            const runs = historyData.history || [];
            
            if (index === -1) {
                selectedTimeText.innerText = 'Consolidated timeline of all patch modifications';
                
                let totalAdded = 0;
                let totalRemoved = 0;
                let latestTotal = 0;
                let latestRun = null;
                
                if (runs.length > 0) {
                    latestRun = runs[runs.length - 1];
                    latestTotal = latestRun.summary.total;
                    for (let i = 0; i < runs.length; i++) {
                        totalAdded += runs[i].summary.added || 0;
                        totalRemoved += runs[i].summary.removed || 0;
                    }
                }
                
                countAddedText.innerText = totalAdded;
                countRemovedText.innerText = totalRemoved;
                countTotalText.innerText = latestTotal;
                
                // Render resources using latest available metrics
                const dests = historyData.destinations;
                const latestMetrics = latestRun ? latestRun.system_metrics : null;
                
                if (latestMetrics || dests) {
                    resourcesPanel.style.display = 'grid';
                    if (latestMetrics) {
                        osInfoText.innerText = latestMetrics.os_name + ' (Build ' + latestMetrics.os_build + ')';
                        cpuInfoText.innerText = latestMetrics.cpu_name + ' (' + latestMetrics.cpu_cores + ' cores)';
                        
                        const ramTotal = latestMetrics.ram_total_gb;
                        const ramUsed = latestMetrics.ram_used_gb;
                        const ramPct = Math.round((ramUsed / ramTotal) * 100);
                        ramValueText.innerText = ramUsed + ' GB / ' + ramTotal + ' GB (' + ramPct + '%)';
                        ramBarFill.style.width = ramPct + '%';

                        const storageTotal = latestMetrics.storage_total;
                        const storageUsed = latestMetrics.storage_used;
                        const storagePct = latestMetrics.storage_pct;
                        storageValueText.innerText = storageUsed + ' GB / ' + storageTotal + ' GB (' + storagePct + '%)';
                        storageBarFill.style.width = storagePct + '%';
                    } else {
                        osInfoText.innerText = '-';
                        cpuInfoText.innerText = '-';
                        ramValueText.innerText = '-';
                        ramBarFill.style.width = '0%';
                        storageValueText.innerText = '-';
                        storageBarFill.style.width = '0%';
                    }

                    if (dests) {
                        document.getElementById('dest-smb').innerText = 'SMB: ' + (dests.smb || 'Not Configured');
                        document.getElementById('dest-smtp').innerText = 'SMTP: ' + (dests.smtp || 'Not Configured');
                        document.getElementById('dest-local').innerText = 'Local: ' + (dests.local || '-');
                        document.getElementById('dest-smb').title = dests.smb || '';
                        document.getElementById('dest-smtp').title = dests.smtp || '';
                        document.getElementById('dest-local').title = dests.local || '';
                    }
                } else {
                    resourcesPanel.style.display = 'none';
                }

                // Render overall diff table with 4 columns
                const headerRow = document.getElementById('table-header-row');
                if (headerRow) {
                    headerRow.innerHTML = 
                        '<th style="width: 35%;">Hotfix / Knowledge Base</th>' +
                        '<th style="width: 20%;">Action</th>' +
                        '<th style="width: 25%;">Change Date</th>' +
                        '<th style="width: 20%;">Installed On</th>';
                }
                
                renderOverallTableRows(getOverallLogDiffs());
                return;
            }

            // Individual Run Selection
            const run = runs[index];
            if (!run) {
                selectedTimeText.innerText = 'No run selected';
                resourcesPanel.style.display = 'none';
                return;
            }

            selectedTimeText.innerText = formatDate(run.timestamp);
            countAddedText.innerText = run.summary.added;
            countRemovedText.innerText = run.summary.removed;
            countTotalText.innerText = run.summary.total;

            const dests = run.destinations || historyData.destinations;
            if (run.system_metrics || dests) {
                resourcesPanel.style.display = 'grid';
                if (run.system_metrics) {
                    osInfoText.innerText = run.system_metrics.os_name + ' (Build ' + run.system_metrics.os_build + ')';
                    cpuInfoText.innerText = run.system_metrics.cpu_name + ' (' + run.system_metrics.cpu_cores + ' cores)';
                    
                    const ramTotal = run.system_metrics.ram_total_gb;
                    const ramUsed = run.system_metrics.ram_used_gb;
                    const ramPct = Math.round((ramUsed / ramTotal) * 100);
                    ramValueText.innerText = ramUsed + ' GB / ' + ramTotal + ' GB (' + ramPct + '%)';
                    ramBarFill.style.width = ramPct + '%';

                    const storageTotal = run.system_metrics.storage_total;
                    const storageUsed = run.system_metrics.storage_used;
                    const storagePct = run.system_metrics.storage_pct;
                    storageValueText.innerText = storageUsed + ' GB / ' + storageTotal + ' GB (' + storagePct + '%)';
                    storageBarFill.style.width = storagePct + '%';
                } else {
                    osInfoText.innerText = '-';
                    cpuInfoText.innerText = '-';
                    ramValueText.innerText = '-';
                    ramBarFill.style.width = '0%';
                    storageValueText.innerText = '-';
                    storageBarFill.style.width = '0%';
                }

                if (dests) {
                    document.getElementById('dest-smb').innerText = 'SMB: ' + (dests.smb || 'Not Configured');
                    document.getElementById('dest-smtp').innerText = 'SMTP: ' + (dests.smtp || 'Not Configured');
                    document.getElementById('dest-local').innerText = 'Local: ' + (dests.local || '-');
                    document.getElementById('dest-smb').title = dests.smb || '';
                    document.getElementById('dest-smtp').title = dests.smtp || '';
                    document.getElementById('dest-local').title = dests.local || '';
                }
            } else {
                resourcesPanel.style.display = 'none';
            }

            // Restore original 3 columns for individual runs
            const headerRow = document.getElementById('table-header-row');
            if (headerRow) {
                headerRow.innerHTML = 
                    '<th style="width: 45%;">Hotfix / Knowledge Base</th>' +
                    '<th style="width: 25%;">Action</th>' +
                    '<th style="width: 30%;">Installation Date</th>';
            }

            renderTableRows(run.diff || []);
        }

        // Render table rows for selected run
        function renderTableRows(diffList) {
            const filtered = diffList.filter(item => {
                const matchesFilter = currentFilter === 'all' || item.action === currentFilter;
                const matchesSearch = item.kb_id.toLowerCase().includes(searchQuery.toLowerCase());
                return matchesFilter && matchesSearch;
            });

            if (filtered.length === 0) {
                tableBody.innerHTML = '';
                emptyState.style.display = 'flex';
                document.getElementById('table-status').style.display = 'none';
                return;
            }

            emptyState.style.display = 'none';
            
            const totalCount = filtered.length;
            const limitCount = displayLimit === -1 ? totalCount : Math.min(displayLimit, totalCount);

            let rowsHtml = '';
            for (let i = 0; i < limitCount; i++) {
                const item = filtered[i];
                const badgeClass = item.action === 'added' ? 'badge-added' : 'badge-removed';
                const actionText = item.action === 'added' ? 'Added' : 'Removed';
                const actionIcon = item.action === 'added' 
                    ? '<svg style="width:12px;height:12px;fill:none;stroke:currentColor;stroke-width:3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" /></svg>'
                    : '<svg style="width:12px;height:12px;fill:none;stroke:currentColor;stroke-width:3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M19.5 12h-15" /></svg>';

                const dateStr = item.installed_on ? item.installed_on : 'Unknown';
                const cleanKbId = item.kb_id.replace(/\D/g, '');

                rowsHtml += '<tr>' +
                            '<td>' +
                                '<div class="kb-cell">' +
                                    '<a href="https://support.microsoft.com/help/' + cleanKbId + '" target="_blank" class="kb-link">' + item.kb_id + '</a>' +
                                    '<button class="copy-btn" onclick="copyToClipboard(\'' + item.kb_id + '\', this)" title="Copy KB ID">' +
                                        '<svg style="width:14px;height:14px;fill:none;stroke:currentColor;stroke-width:2" viewBox="0 0 24 24">' +
                                            '<path stroke-linecap="round" stroke-linejoin="round" d="M8.25 7.5V6.108c0-1.135.845-2.098 1.976-2.192.373-.03.748-.057 1.123-.08M15.75 18H18a2.25 2.25 0 002.25-2.25V6.108c0-1.135-.845-2.098-1.976-2.192a48.424 48.424 0 00-1.123-.08M15.75 18.75v-1.875a3.375 3.375 0 00-3.375-3.375h-1.5a1.125 1.125 0 01-1.125-1.125v-1.5A3.375 3.375 0 006.375 7.5H5.25m11.9-3.664A2.251 2.251 0 0015 2.25h-1.5a2.251 2.251 0 00-2.15 1.586m5.8 0c.065.21.1.433.1.664v.75h-6V4.5c0-.231.035-.454.1-.664M6.75 7.5H4.875c-.621 0-1.125.504-1.125 1.125v12c0 .621.504 1.125 1.125 1.125h9.75c.621 0 1.125-.504 1.125-1.125V16.5a9 9 0 00-9-9z" />' +
                                        '</svg>' +
                                    '</button>' +
                                '</div>' +
                            '</td>' +
                            '<td>' +
                                '<span class="badge-action ' + badgeClass + '">' +
                                    actionIcon +
                                    ' <span style="margin-left: 0.25rem;">' + actionText + '</span>' +
                                '</span>' +
                            '</td>' +
                            '<td class="installed-date">' + dateStr + '</td>' +
                          '</tr>';
            }
            tableBody.innerHTML = rowsHtml;

            const tableStatus = document.getElementById('table-status');
            if (tableStatus) {
                if (totalCount > limitCount) {
                    tableStatus.style.display = 'block';
                    tableStatus.innerText = 'Showing ' + limitCount + ' of ' + totalCount + ' changes. Use the "Show" dropdown to view more.';
                } else {
                    tableStatus.style.display = 'none';
                }
            }
        }

        // Render table rows for consolidated overall log
        function renderOverallTableRows(allDiffs) {
            const filtered = allDiffs.filter(item => {
                const matchesFilter = currentFilter === 'all' || item.action === currentFilter;
                const matchesSearch = item.kb_id.toLowerCase().includes(searchQuery.toLowerCase());
                return matchesFilter && matchesSearch;
            });

            if (filtered.length === 0) {
                tableBody.innerHTML = '';
                emptyState.style.display = 'flex';
                document.getElementById('table-status').style.display = 'none';
                return;
            }

            emptyState.style.display = 'none';
            
            const totalCount = filtered.length;
            const limitCount = displayLimit === -1 ? totalCount : Math.min(displayLimit, totalCount);

            let rowsHtml = '';
            for (let i = 0; i < limitCount; i++) {
                const item = filtered[i];
                const badgeClass = item.action === 'added' ? 'badge-added' : 'badge-removed';
                const actionText = item.action === 'added' ? 'Added' : 'Removed';
                const actionIcon = item.action === 'added' 
                    ? '<svg style="width:12px;height:12px;fill:none;stroke:currentColor;stroke-width:3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" /></svg>'
                    : '<svg style="width:12px;height:12px;fill:none;stroke:currentColor;stroke-width:3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M19.5 12h-15" /></svg>';

                const instDateStr = item.installed_on ? item.installed_on : 'Unknown';
                const changeDateStr = formatDate(item.run_timestamp).split(',')[0]; // Only show the date part
                const cleanKbId = item.kb_id.replace(/\D/g, '');

                rowsHtml += '<tr>' +
                            '<td>' +
                                '<div class="kb-cell">' +
                                    '<a href="https://support.microsoft.com/help/' + cleanKbId + '" target="_blank" class="kb-link">' + item.kb_id + '</a>' +
                                    '<button class="copy-btn" onclick="copyToClipboard(\'' + item.kb_id + '\', this)" title="Copy KB ID">' +
                                        '<svg style="width:14px;height:14px;fill:none;stroke:currentColor;stroke-width:2" viewBox="0 0 24 24">' +
                                            '<path stroke-linecap="round" stroke-linejoin="round" d="M8.25 7.5V6.108c0-1.135.845-2.098 1.976-2.192.373-.03.748-.057 1.123-.08M15.75 18H18a2.25 2.25 0 002.25-2.25V6.108c0-1.135-.845-2.098-1.976-2.192a48.424 48.424 0 00-1.123-.08M15.75 18.75v-1.875a3.375 3.375 0 00-3.375-3.375h-1.5a1.125 1.125 0 01-1.125-1.125v-1.5A3.375 3.375 0 006.375 7.5H5.25m11.9-3.664A2.251 2.251 0 0015 2.25h-1.5a2.251 2.251 0 00-2.15 1.586m5.8 0c.065.21.1.433.1.664v.75h-6V4.5c0-.231.035-.454.1-.664M6.75 7.5H4.875c-.621 0-1.125.504-1.125 1.125v12c0 .621.504 1.125 1.125 1.125h9.75c.621 0 1.125-.504 1.125-1.125V16.5a9 9 0 00-9-9z" />' +
                                        '</svg>' +
                                    '</button>' +
                                '</div>' +
                            '</td>' +
                            '<td>' +
                                '<span class="badge-action ' + badgeClass + '">' +
                                    actionIcon +
                                    ' <span style="margin-left: 0.25rem;">' + actionText + '</span>' +
                                '</span>' +
                            '</td>' +
                            '<td>' + changeDateStr + '</td>' +
                            '<td class="installed-date">' + instDateStr + '</td>' +
                          '</tr>';
            }
            tableBody.innerHTML = rowsHtml;

            const tableStatus = document.getElementById('table-status');
            if (tableStatus) {
                if (totalCount > limitCount) {
                    tableStatus.style.display = 'block';
                    tableStatus.innerText = 'Showing ' + limitCount + ' of ' + totalCount + ' changes. Use the "Show" dropdown to view more.';
                } else {
                    tableStatus.style.display = 'none';
                }
            }
        }

        // Copy KB ID to clipboard
        window.copyToClipboard = function(text, btn) {
            navigator.clipboard.writeText(text).then(() => {
                const originalHtml = btn.innerHTML;
                btn.innerHTML = '<svg style="width:14px;height:14px;fill:none;stroke:#10b981;stroke-width:2.5" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M4.5 12.75l6 6 9-13.5" /></svg>';
                setTimeout(() => {
                    btn.innerHTML = originalHtml;
                }, 1000);
            }).catch(err => {
                console.error('Could not copy text: ', err);
            });
        }

        // Search hook
        searchBar.addEventListener('input', (e) => {
            searchQuery = e.target.value;
            if (activeRunIndex === -1) {
                renderOverallTableRows(getOverallLogDiffs());
            } else {
                const runs = historyData.history || [];
                const run = runs[activeRunIndex];
                if (run) {
                    renderTableRows(run.diff || []);
                }
            }
        });

        // Tabs hook
        filterTabs.forEach(tab => {
            tab.addEventListener('click', () => {
                filterTabs.forEach(t => t.classList.remove('active'));
                tab.classList.add('active');
                currentFilter = tab.getAttribute('data-filter');
                if (activeRunIndex === -1) {
                    renderOverallTableRows(getOverallLogDiffs());
                } else {
                    const runs = historyData.history || [];
                    const run = runs[activeRunIndex];
                    if (run) {
                        renderTableRows(run.diff || []);
                    }
                }
            });
        });

        // Setup JSON link dynamically based on file naming convention
        const jsonLink = document.getElementById('json-link');
        if (jsonLink) {
            const currentFile = window.location.pathname.split('/').pop();
            if (currentFile === 'dashboard.html') {
                jsonLink.href = './report.json';
            } else if (currentFile === 'demo-dashboard.html') {
                jsonLink.href = './demo-report.json';
            } else if (historyData.computer_name) {
                jsonLink.href = './' + historyData.computer_name + '-report.json';
            }
        }

        // Initialize display to Overall Change Log
        selectOverallLog();
    </script>
</body>
</html>
"@

    $HtmlContent | Out-File -FilePath $HtmlFilePath -Encoding UTF8 -Force
}

#endregion

if (-not (Get-Variable -Name PatchStateAgentTestMode -Scope Global -ValueOnly -ErrorAction SilentlyContinue)) {
    try {
        Write-AgentLog -Level 'INFO' -Message "===== $Script:AgentName run started on $($env:COMPUTERNAME) ====="

        # Step 1: Self-heal environment before doing anything else
        Initialize-Environment

        # Step 2: Honour orchestrator override (Windmill)
        if (-not $BypassOrchestratorCheck -and (Test-OrchestratorOverride)) {
            exit 0
        }

        # Step 3: Load previous state (corruption-safe)
        $PreviousState = Read-StateFile -FilePath $Script:PreviousStateFile

        # Step 4: Capture current patch state (WMI-timeout-safe)
        $CurrentState = Get-PatchState

        # Step 5: Compute diff and build report
        $Report = Compare-PatchState -CurrentState $CurrentState -PreviousState $PreviousState

        # Step 6: Persist current state atomically
        #   a. Archive current -> previous (for next run's comparison)
        if (Test-PathExists -Path $Script:CurrentStateFile) {
            Write-StateFile -FilePath $Script:PreviousStateFile -Data (Read-StateFile -FilePath $Script:CurrentStateFile)
        }
        #   b. Write new current state
        Write-StateFile -FilePath $Script:CurrentStateFile -Data $CurrentState

        # Also persist the full report as patch_report.json (latest copy, for reference)
        $LatestReportFile = Join-Path $Script:StateDir 'patch_report.json'
        Write-StateFile -FilePath $LatestReportFile -Data $Report

        # Step 7: Load, Update, and Compile historical dashboard
        $HistoryJsonFile = Join-Path $Script:StateDir "$($env:COMPUTERNAME)-report.json"
        $HistoryHtmlFile = Join-Path $Script:StateDir "$($env:COMPUTERNAME)-dashboard.html"

        # Resolve configuration values (registry config with parameter override/fallback)
        $HistoryLimitValue = if ($PSBoundParameters.ContainsKey('HistoryLimit')) { $HistoryLimit } else { Get-RegistryConfig -ValueName 'HistoryLimit' -DefaultValue 30 }
        $MaxDisplayChangesValue = if ($PSBoundParameters.ContainsKey('MaxDisplayChanges')) { $MaxDisplayChanges } else { Get-RegistryConfig -ValueName 'MaxDisplayChanges' -DefaultValue 50 }

        $HistoryData = @{
            computer_name       = $env:COMPUTERNAME
            tag                 = (Get-RegistryConfig -ValueName 'ServerTag' -DefaultValue 'Untagged')
            max_display_changes = $MaxDisplayChangesValue
            destinations        = [PSCustomObject]@{
                smb   = (Get-RegistryConfig -ValueName 'SmbPath' -DefaultValue 'Not Configured')
                smtp  = if (Get-RegistryConfig -ValueName 'SmtpServer') { 
                            "$((Get-RegistryConfig -ValueName 'SmtpServer')) (to: $((Get-RegistryConfig -ValueName 'SmtpTo')))" 
                        } else { 
                            'Not Configured' 
                        }
                local = $Script:StateDir
            }
            history             = @()
        }

        if (Test-PathExists -Path $HistoryJsonFile) {
            try {
                $RawJson = Get-Content -Raw -Path $HistoryJsonFile -ErrorAction Stop
                $Parsed  = ConvertFrom-Json -InputObject $RawJson -ErrorAction Stop
                if ($Parsed -and $Parsed.history) {
                    $HistoryData.history = @($Parsed.history)
                }
            }
            catch {
                Write-AgentLog -Level 'WARN' -Message "History file was corrupt, recreating. Error: $_"
            }
        }

        # Create new run entry with system resource metrics
        $NewRunReport = [PSCustomObject]@{
            timestamp             = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
            orchestrator_override = $false
            summary               = $Report.summary
            diff                  = $Report.diff
            system_metrics        = (Get-SystemMetrics)
        }

        # Append and trim history
        $HistoryList = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($Item in $HistoryData.history) {
            $HistoryList.Add($Item)
        }
        $HistoryList.Add($NewRunReport)

        while ($HistoryList.Count -gt $HistoryLimitValue) {
            $HistoryList.RemoveAt(0)
        }
        $HistoryData.history = $HistoryList.ToArray()

        # Save historical reports
        Write-StateFile -FilePath $HistoryJsonFile -Data $HistoryData
        Export-PatchHtml -HistoryData $HistoryData -HtmlFilePath $HistoryHtmlFile

        # Step 8: Transmit report files via cascading transport
        Send-PatchReport -JsonFilePath $HistoryJsonFile -HtmlFilePath $HistoryHtmlFile

        Write-AgentLog -Level 'INFO' -Message "===== $Script:AgentName run completed successfully ====="
    }
    catch {
        # Outer safety net: any unhandled exception is logged and the script exits cleanly
        # (Never crash silently - always leave a trace)
        try {
            Write-AgentLog -Level 'ERROR' -Message "Unhandled fatal exception in $Script:AgentName run: $_"
        }
        catch {
            # If even logging fails, last resort: write to stderr
            Write-Error "FATAL: $Script:AgentName crashed and logging failed. Error: $_"
        }
        exit 1
    }
}

