<#
.SYNOPSIS
    Generates a premium, clean demo version of the HTML dashboard and JSON report
    with simulated data for the public GitHub repository (hiding personal info).
.DESCRIPTION
    1. Dot-sources the main agent script in test mode to import the HTML compiler.
    2. Builds a realistic, multi-run mock history payload for a fictional server (DEMO-SRV-01).
    3. Exports the mock data as demo-report.json and compiles demo-dashboard.html.
#>

$global:PatchStateAgentTestMode = $true
$AgentScript = Join-Path $PSScriptRoot 'src\PatchStateAgent.ps1'

if (-not (Test-Path $AgentScript)) {
    Write-Error "Could not find agent script at $AgentScript"
    exit 1
}

# Import functions from agent script without executing it
. $AgentScript

# Define realistic mock runs spanning a month
$MockHistory = @()

# Fictional system metrics for our demo server
$DemoMetrics = [PSCustomObject]@{
    os_name        = "Microsoft Windows Server 2025 Standard"
    os_version     = "10.0.26100"
    os_build       = "26100"
    cpu_name       = "Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz"
    cpu_cores      = 8
    ram_total_gb   = 32.0
    ram_used_gb    = 14.2
    storage_total  = 500.0
    storage_used   = 214.5
    storage_pct    = 42.9
}

# Run 1: Initial Baseline Setup (30 days ago)
$MockHistory += [PSCustomObject]@{
    timestamp             = "2026-05-05T09:00:00Z"
    orchestrator_override = $false
    summary               = [PSCustomObject]@{ added = 15; removed = 0; total = 15 }
    system_metrics        = $DemoMetrics
    diff                  = @(
        [PSCustomObject]@{ kb_id = "KB5000101"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000102"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000103"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000104"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000105"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000106"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000107"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000108"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000109"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000110"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000111"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000112"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000113"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000114"; action = "added"; installed_on = "2026-05-05" }
        [PSCustomObject]@{ kb_id = "KB5000115"; action = "added"; installed_on = "2026-05-05" }
    )
}

# Run 2: Security Patch Cycle (15 days ago)
$MockHistory += [PSCustomObject]@{
    timestamp             = "2026-05-20T10:15:00Z"
    orchestrator_override = $false
    summary               = [PSCustomObject]@{ added = 2; removed = 0; total = 17 }
    system_metrics        = $DemoMetrics
    diff                  = @(
        [PSCustomObject]@{ kb_id = "KB5010201"; action = "added"; installed_on = "2026-05-20" }
        [PSCustomObject]@{ kb_id = "KB5010202"; action = "added"; installed_on = "2026-05-20" }
    )
}

# Run 3: Rollback of unstable KB (10 days ago)
$MockHistory += [PSCustomObject]@{
    timestamp             = "2026-05-25T14:30:00Z"
    orchestrator_override = $false
    summary               = [PSCustomObject]@{ added = 0; removed = 1; total = 16 }
    system_metrics        = $DemoMetrics
    diff                  = @(
        [PSCustomObject]@{ kb_id = "KB5010202"; action = "removed"; installed_on = "2026-05-20" }
    )
}

# Run 4: Cumulative Update (2 days ago)
$MockHistory += [PSCustomObject]@{
    timestamp             = "2026-06-02T09:45:00Z"
    orchestrator_override = $true
    summary               = [PSCustomObject]@{ added = 3; removed = 0; total = 19 }
    system_metrics        = $DemoMetrics
    diff                  = @(
        [PSCustomObject]@{ kb_id = "KB5020301"; action = "added"; installed_on = "2026-06-02" }
        [PSCustomObject]@{ kb_id = "KB5020302"; action = "added"; installed_on = "2026-06-02" }
        [PSCustomObject]@{ kb_id = "KB5020303"; action = "added"; installed_on = "2026-06-02" }
    )
}

# Run 5: Clean Daily Verification (Today)
$MockHistory += [PSCustomObject]@{
    timestamp             = "2026-06-04T08:00:00Z"
    orchestrator_override = $false
    summary               = [PSCustomObject]@{ added = 0; removed = 0; total = 19 }
    system_metrics        = $DemoMetrics
    diff                  = @()
}

$DemoHistoryData = @{
    computer_name       = "DEMO-SRV-01"
    tag                 = "Production-Web"
    max_display_changes = 50
    destinations        = [PSCustomObject]@{
        smb   = "\\shared-storage.acme.corp\reports\Production-Web\DEMO-SRV-01"
        smtp  = "smtp.relay.acme.corp (to: patch-reports@acme.corp)"
        local = "C:\ProgramData\PatchStateAgent\State"
    }
    history             = $MockHistory
}

$DestJson = Join-Path $PSScriptRoot 'demo-report.json'
$DestHtml = Join-Path $PSScriptRoot 'demo-dashboard.html'

# Save JSON file
$DemoHistoryDataJson = ConvertTo-Json -InputObject $DemoHistoryData -Depth 10
$DemoHistoryDataJson | Out-File -FilePath $DestJson -Encoding UTF8 -Force

# Compile and save HTML dashboard
Export-PatchHtml -HistoryData $DemoHistoryData -HtmlFilePath $DestHtml

Write-Host "[+] Fictional demo report JSON generated: $DestJson" -ForegroundColor Green
Write-Host "[+] Fictional demo HTML dashboard compiled: $DestHtml" -ForegroundColor Green
