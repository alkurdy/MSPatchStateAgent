<#
.SYNOPSIS
    Chocolatey Installation Script for PatchStateAgent.
.DESCRIPTION
    Provisioning script designed to deploy the agent:
    1. Create ProgramData folders (C:\ProgramData\PatchStateAgent\...).
    2. Copy PatchStateAgent.ps1 into place.
    3. Save parameters in Registry config.
    4. Register local Windows Scheduled Task running daily as SYSTEM.
#>
$packageName = 'patchstateagent'
$toolsDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Default installation directory target
$InstallDir = Join-Path $env:ProgramData "PatchStateAgent"

# TODO: Retrieve package parameters using Get-PackageParameters
# Supported parameters:
#   /ServerTag: e.g., 'Web', 'SQL', 'DMZ'
#   /SmbPath: target UNC path
#   /SmtpServer: fallback SMTP relay server

Write-Output "Staging installation steps for package $packageName..."

# 1. Create target directories:
#    - C:\ProgramData\PatchStateAgent\
#    - C:\ProgramData\PatchStateAgent\Logs\
#    - C:\ProgramData\PatchStateAgent\State\
#    - C:\ProgramData\PatchStateAgent\undelivered\

# 2. Deploy PatchStateAgent.ps1 script file to $InstallDir

# 3. Set Registry configuration values in:
#    HKLM:\SOFTWARE\PatchStateAgent\Config\
#    HKLM:\SOFTWARE\PatchStateAgent\OrchestratorTriggered (initialize as 0)

# 4. Define and register Scheduled Task running daily under 'NT AUTHORITY\SYSTEM'
#    Task Name: "PatchStateAgent-Daily"
#    Command: powershell.exe -ExecutionPolicy Bypass -File "$InstallDir\PatchStateAgent.ps1"
