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
    [switch]$SimulateSmtpFailure
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
        downstream AI/API consumption as defined in the spec.
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
        Attempts to write the report JSON to the configured SMB share.
    .DESCRIPTION
        Uses a Job with a bounded timeout to prevent indefinite network hangs.
    .OUTPUTS
        [bool] $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ReportJson,

        [Parameter(Mandatory)]
        [string]$FileName
    )

    $SmbPath = Get-RegistryConfig -ValueName 'SmbPath' -DefaultValue ''
    $Tag     = Get-RegistryConfig -ValueName 'ServerTag' -DefaultValue 'Untagged'

    if ([string]::IsNullOrWhiteSpace($SmbPath)) {
        Write-AgentLog -Level 'WARN' -Message 'SMB upload skipped: no SmbPath configured.'
        return $false
    }

    # Build per-tag, per-host directory
    $TargetDir  = Join-Path $SmbPath (Join-Path $Tag $env:COMPUTERNAME)
    $TargetFile = Join-Path $TargetDir $FileName

    Write-AgentLog -Level 'INFO' -Message "Attempting SMB upload to: $TargetFile"

    # Run inside a bounded job to prevent indefinite network hang
    $Job = Start-Job -ScriptBlock {
        param ($ReportJson, $TargetDir, $TargetFile)
        if (-not (Test-Path $TargetDir)) {
            $null = New-Item -Path $TargetDir -ItemType Directory -Force -ErrorAction Stop
        }
        [System.IO.File]::WriteAllText($TargetFile, $ReportJson, [System.Text.Encoding]::UTF8)
    } -ArgumentList $ReportJson, $TargetDir, $TargetFile

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
        Sends the report JSON as an email attachment to the configured ingestion mailbox.
    .OUTPUTS
        [bool] $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ReportJson,

        [Parameter(Mandatory)]
        [string]$FileName
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
        # Write report to a temp attachment file (Send-MailMessage requires a file path)
        $TempAttachment = Join-Path $env:TEMP "$FileName.tmp"
        $ReportJson | Out-File -FilePath $TempAttachment -Encoding UTF8 -Force

        $MailParams = @{
            SmtpServer  = $SmtpServer
            Port        = [int]$SmtpPort
            From        = $SmtpFrom
            To          = $SmtpTo
            Subject     = "[$Script:AgentName] Patch Report - $($env:COMPUTERNAME) - $(Get-Date -Format 'yyyy-MM-dd')"
            Body        = "PatchStateAgent report attached as JSON. Computer: $($env:COMPUTERNAME)"
            Attachments = $TempAttachment
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
    finally {
        if (Test-Path $TempAttachment) { Remove-Item -Path $TempAttachment -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-LocalCache {
    <#
    .SYNOPSIS
        Saves the report JSON to the local undelivered cache as a last resort.
    .OUTPUTS
        [bool] $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ReportJson,

        [Parameter(Mandatory)]
        [string]$FileName
    )

    Write-AgentLog -Level 'WARN' -Message 'All transport methods exhausted. Caching report locally.'

    try {
        $TargetFile = Join-Path $Script:UndeliveredDir $FileName
        $ReportJson | Out-File -FilePath $TargetFile -Encoding UTF8 -Force -ErrorAction Stop
        Write-AgentLog -Level 'WARN' -Message "Report cached locally at: $TargetFile"
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
        Delivers the patch report via cascading transport: SMB -> SMTP -> Local Cache.
    .DESCRIPTION
        Attempts each delivery method in priority order. Stops at the first success.
        All transport functions return a boolean result so this function is clean
        and easy to follow (spacecraft rule: simple control flow, no deep nesting).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ReportJson
    )

    # Generate a unique, timestamped filename for this report
    $Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $FileName  = "patch_report_$($env:COMPUTERNAME)_$Timestamp.json"

    # Priority 1: SMB (unless simulated failure is requested)
    if (-not $Script:SimulateSmbFailure) {
        if (Invoke-SmbUpload -ReportJson $ReportJson -FileName $FileName) { return }
    }
    else {
        Write-AgentLog -Level 'WARN' -Message 'SimulateSmbFailure is active - bypassing SMB upload.'
    }

    # Priority 2: SMTP (unless simulated failure is requested)
    if (-not $Script:SimulateSmtpFailure) {
        if (Invoke-SmtpDelivery -ReportJson $ReportJson -FileName $FileName) { return }
    }
    else {
        Write-AgentLog -Level 'WARN' -Message 'SimulateSmtpFailure is active - bypassing SMTP delivery.'
    }

    # Priority 3: Local Cache (last resort)
    $null = Invoke-LocalCache -ReportJson $ReportJson -FileName $FileName
}

#endregion

if (-not $global:PatchStateAgentTestMode) {
    try {
        Write-AgentLog -Level 'INFO' -Message "===== $Script:AgentName run started on $($env:COMPUTERNAME) ====="

        # Step 1: Self-heal environment before doing anything else
        Initialize-Environment

        # Step 2: Honour orchestrator override (Windmill)
        if (Test-OrchestratorOverride) {
            exit 0
        }

        # Step 3: Load previous state (corruption-safe)
        $PreviousState = Read-StateFile -FilePath $Script:PreviousStateFile

        # Step 4: Capture current patch state (WMI-timeout-safe)
        $CurrentState = Get-PatchState

        # Step 5: Compute diff and build report
        $Report     = Compare-PatchState -CurrentState $CurrentState -PreviousState $PreviousState
        $ReportJson = ConvertTo-Json -InputObject $Report -Depth 10

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

        # Step 7: Transmit report via cascading transport
        Send-PatchReport -ReportJson $ReportJson

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
