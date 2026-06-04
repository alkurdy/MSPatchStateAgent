<#
.SYNOPSIS
    Chocolatey Uninstallation Script for PatchStateAgent.
.DESCRIPTION
    Cleanup routine designed to tear down agent registration safely:
    1. Delete the "PatchStateAgent-Daily" scheduled task.
    2. Clean up configuration registry keys (HKLM:\SOFTWARE\PatchStateAgent).
    3. Safely delete the deployed agent scripts.
    4. Optional: Retain logs and state files under C:\ProgramData\PatchStateAgent for safety.
#>
$packageName = 'patchstateagent'

Write-Output "Staging uninstallation steps for package $packageName..."

# 1. Unregister Windows Scheduled Task: "PatchStateAgent-Daily"

# 2. Remove configuration keys:
#    HKLM:\SOFTWARE\PatchStateAgent\

# 3. Clean up installation files (but optionally preserve logs/state in C:\ProgramData\PatchStateAgent)
