<#
.SYNOPSIS
    Runs the PatchStateAgent locally and copies the compiled historical dashboard.
.DESCRIPTION
    1. Executes the main PatchStateAgent script to generate the latest historical reports.
    2. Copies the updated dashboard HTML and report JSON from ProgramData to the workspace.
    3. Opens the dashboard in the default web browser.
#>

$AgentScript = Join-Path $PSScriptRoot 'src\PatchStateAgent.ps1'
$HostName    = $env:COMPUTERNAME

$SourceHtml  = Join-Path $env:ProgramData "PatchStateAgent\State\$HostName-dashboard.html"
$SourceJson  = Join-Path $env:ProgramData "PatchStateAgent\State\$HostName-report.json"

$DestHtml    = Join-Path $PSScriptRoot 'dashboard.html'
$DestJson    = Join-Path $PSScriptRoot 'report.json'

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  PatchStateAgent Historical Report Runner    " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 1. Ensure Agent Script exists
if (-not (Test-Path $AgentScript)) {
    Write-Error "Could not find agent script at $AgentScript"
    exit 1
}

# 2. Run the agent locally in non-test mode
Write-Host "[*] Executing PatchStateAgent locally to generate/append run data..." -ForegroundColor Yellow
$global:PatchStateAgentTestMode = $false
& $AgentScript

# 3. Copy files to local workspace for viewing
if (-not (Test-Path $SourceHtml)) {
    Write-Error "Agent executed but did not generate the historical dashboard at $SourceHtml"
    exit 1
}

Copy-Item -Path $SourceHtml -Destination $DestHtml -Force
Copy-Item -Path $SourceJson -Destination $DestJson -Force

Write-Host "[+] Local copy of dashboard updated: $DestHtml" -ForegroundColor Green
Write-Host "[+] Local copy of JSON report updated: $DestJson" -ForegroundColor Green

# 4. Open in default browser
Write-Host "[*] Launching web browser to view dashboard..." -ForegroundColor Yellow
Start-Process $DestHtml

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Done! Check your web browser.               " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
