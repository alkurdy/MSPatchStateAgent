<#
.SYNOPSIS
    Chocolatey uninstallation script for PatchStateAgent.
.DESCRIPTION
    1. Unregisters the PatchStateAgent-Daily scheduled task.
    2. Removes the agent script from C:\ProgramData\PatchStateAgent\.
    3. Removes the registry configuration keys.
    4. Intentionally PRESERVES logs, state history, and undelivered reports
       under C:\ProgramData\PatchStateAgent\ for forensic/audit continuity.
       (The administrator may manually delete these if desired.)
#>

$packageName = 'patchstateagent'
$TaskName    = 'PatchStateAgent-Daily'
$InstallDir  = Join-Path $env:ProgramData 'PatchStateAgent'
$AgentDest   = Join-Path $InstallDir 'PatchStateAgent.ps1'
$RegRoot     = 'HKLM:\SOFTWARE\PatchStateAgent'

Write-Host "[$packageName] Uninstalling PatchStateAgent..."

# --- Step 1: Unregister Scheduled Task ---
$Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($Task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[$packageName] Scheduled task '$TaskName' removed."
}
else {
    Write-Host "[$packageName] Scheduled task '$TaskName' not found (already removed)."
}

# --- Step 2: Remove Agent Script ---
if (Test-Path $AgentDest) {
    Remove-Item -Path $AgentDest -Force -ErrorAction SilentlyContinue
    Write-Host "[$packageName] Agent script removed from: $AgentDest"
}

# --- Step 3: Remove Registry Configuration ---
if (Test-Path $RegRoot) {
    Remove-Item -Path $RegRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[$packageName] Registry keys removed: $RegRoot"
}

# --- Step 4: Preserve audit data (logs, state, undelivered) ---
Write-Host "[$packageName] NOTE: Logs, state history, and undelivered reports are preserved at: $InstallDir"
Write-Host "[$packageName] Remove this directory manually if it is no longer needed."

Write-Host "[$packageName] Uninstallation complete."
