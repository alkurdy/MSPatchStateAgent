<#
.SYNOPSIS
    Pester unit tests for PatchStateAgent (PSA).
.DESCRIPTION
    Covers three test areas as defined in SPEC.md Section 6:
      1. Diff Engine accuracy (added/removed/unchanged KB detection)
      2. Orchestrator semaphore check behaviour
      3. Cascading transport fallback logic

    Compatible with Pester v5+. To run:
        Invoke-Pester -Path .\tests\PatchStateAgent.Tests.ps1 -Output Detailed

    To run against staged script with no transport secrets:
        Invoke-Pester -Path .\tests\PatchStateAgent.Tests.ps1 -Tag 'Unit'
#>

#region --- Test Setup ---

BeforeAll {
    # Dot-source the agent script to load functions into test scope.
    # We use a try/catch so that the outer script body (which calls exit) does not
    # run during test loading - only function definitions are imported.
    $AgentScript = Join-Path $PSScriptRoot '..\src\PatchStateAgent.ps1'

    if (-not (Test-Path $AgentScript)) {
        throw "Agent script not found at: $AgentScript"
    }

    # Dot-source in a safe scope using -ErrorAction SilentlyContinue for the
    # main block (which tries to connect to Event Log etc.), then re-define stubs.
    . $AgentScript -ErrorAction SilentlyContinue

    # Override Write-AgentLog during tests to suppress file/event log I/O
    function global:Write-AgentLog {
        param ($Level, $Message)
        # No-op during unit tests; captured by Mock below when needed
    }

    # Override Get-RegistryConfig during tests to return controllable defaults
    function global:Get-RegistryConfig {
        param ($ValueName, $DefaultValue = $null)
        return $DefaultValue
    }
}

#endregion

#region --- Test: Diff Engine ---

Describe 'Compare-PatchState - Diff Engine' -Tag 'Unit' {

    Context 'When current state has a KB not in previous state' {
        It 'Should report the new KB as [added]' {
            $Previous = @(
                [PSCustomObject]@{ kb_id = 'KB1000001'; installed_on = '2026-01-01' }
            )
            $Current = @(
                [PSCustomObject]@{ kb_id = 'KB1000001'; installed_on = '2026-01-01' },
                [PSCustomObject]@{ kb_id = 'KB5034123'; installed_on = '2026-06-04' }
            )

            $Report = Compare-PatchState -CurrentState $Current -PreviousState $Previous

            $Added = $Report.diff | Where-Object { $_.action -eq 'added' }
            $Added.Count        | Should -Be 1
            $Added[0].kb_id     | Should -Be 'KB5034123'
            $Added[0].action    | Should -Be 'added'
            $Report.summary.added | Should -Be 1
        }
    }

    Context 'When a KB present in previous state is absent from current state' {
        It 'Should report the missing KB as [removed]' {
            $Previous = @(
                [PSCustomObject]@{ kb_id = 'KB1000001'; installed_on = '2026-01-01' },
                [PSCustomObject]@{ kb_id = 'KB4000099'; installed_on = '2026-03-15' }
            )
            $Current = @(
                [PSCustomObject]@{ kb_id = 'KB1000001'; installed_on = '2026-01-01' }
            )

            $Report = Compare-PatchState -CurrentState $Current -PreviousState $Previous

            $Removed = $Report.diff | Where-Object { $_.action -eq 'removed' }
            $Removed.Count        | Should -Be 1
            $Removed[0].kb_id     | Should -Be 'KB4000099'
            $Removed[0].action    | Should -Be 'removed'
            $Report.summary.removed | Should -Be 1
        }
    }

    Context 'When current and previous states are identical' {
        It 'Should return an empty diff with summary added=0 removed=0' {
            $State = @(
                [PSCustomObject]@{ kb_id = 'KB1000001'; installed_on = '2026-01-01' },
                [PSCustomObject]@{ kb_id = 'KB2000002'; installed_on = '2026-02-14' }
            )

            $Report = Compare-PatchState -CurrentState $State -PreviousState $State

            $Report.diff.Count      | Should -Be 0
            $Report.summary.added   | Should -Be 0
            $Report.summary.removed | Should -Be 0
        }
    }

    Context 'When previous state is empty (first run)' {
        It 'Should report all current KBs as [added]' {
            $Current = @(
                [PSCustomObject]@{ kb_id = 'KB1111111'; installed_on = '2026-05-01' },
                [PSCustomObject]@{ kb_id = 'KB2222222'; installed_on = '2026-05-02' }
            )

            $Report = Compare-PatchState -CurrentState $Current -PreviousState @()

            $Report.summary.added   | Should -Be 2
            $Report.summary.removed | Should -Be 0
        }
    }

    Context 'When both states have mixed changes' {
        It 'Should correctly identify both added and removed KBs simultaneously' {
            $Previous = @(
                [PSCustomObject]@{ kb_id = 'KB1000001'; installed_on = '2026-01-01' },
                [PSCustomObject]@{ kb_id = 'KB9999999'; installed_on = '2026-01-01' }  # will be removed
            )
            $Current = @(
                [PSCustomObject]@{ kb_id = 'KB1000001'; installed_on = '2026-01-01' },
                [PSCustomObject]@{ kb_id = 'KB5034123'; installed_on = '2026-06-04' }  # newly added
            )

            $Report = Compare-PatchState -CurrentState $Current -PreviousState $Previous

            $Report.summary.added   | Should -Be 1
            $Report.summary.removed | Should -Be 1

            ($Report.diff | Where-Object { $_.kb_id -eq 'KB5034123' }).action | Should -Be 'added'
            ($Report.diff | Where-Object { $_.kb_id -eq 'KB9999999' }).action | Should -Be 'removed'
        }
    }

    Context 'Report payload structure' {
        It 'Should include required top-level fields' {
            $Report = Compare-PatchState -CurrentState @() -PreviousState @()

            $Report.timestamp       | Should -Not -BeNullOrEmpty
            $Report.computer_name   | Should -Not -BeNullOrEmpty
            $Report.PSObject.Properties.Name | Should -Contain 'tag'
            $Report.PSObject.Properties.Name | Should -Contain 'orchestrator_override'
            $Report.PSObject.Properties.Name | Should -Contain 'summary'
            $Report.PSObject.Properties.Name | Should -Contain 'diff'
        }
    }
}

#endregion

#region --- Test: Orchestrator Override ---

Describe 'Test-OrchestratorOverride - Semaphore Check' -Tag 'Unit' {

    Context 'When the OrchestratorTriggered registry value is 1' {
        It 'Should return $true and reset the flag to 0' {
            # Mock registry operations
            Mock Test-Path           { $true }                              -ParameterFilter { $Path -like '*PatchStateAgent' }
            Mock Get-ItemProperty    { [PSCustomObject]@{ OrchestratorTriggered = 1 } } -ParameterFilter { $Name -eq 'OrchestratorTriggered' }
            Mock Set-ItemProperty    { } # Capture the reset call
            Mock Write-AgentLog      { }

            $Result = Test-OrchestratorOverride

            $Result | Should -Be $true
            Should -Invoke Set-ItemProperty -Times 1 -ParameterFilter { $Value -eq 0 }
        }
    }

    Context 'When the OrchestratorTriggered registry value is 0' {
        It 'Should return $false and not reset anything' {
            Mock Test-Path        { $true } -ParameterFilter { $Path -like '*PatchStateAgent' }
            Mock Get-ItemProperty { [PSCustomObject]@{ OrchestratorTriggered = 0 } } -ParameterFilter { $Name -eq 'OrchestratorTriggered' }
            Mock Set-ItemProperty { }
            Mock Write-AgentLog   { }

            $Result = Test-OrchestratorOverride

            $Result | Should -Be $false
            Should -Invoke Set-ItemProperty -Times 0
        }
    }

    Context 'When the registry key does not exist' {
        It 'Should return $false gracefully' {
            Mock Test-Path      { $false }
            Mock Write-AgentLog { }

            $Result = Test-OrchestratorOverride

            $Result | Should -Be $false
        }
    }
}

#endregion

#region --- Test: Cascading Transport Layer ---

Describe 'Send-PatchReport - Cascading Transport' -Tag 'Unit' {

    BeforeEach {
        Mock Write-AgentLog   { }
        Mock Get-RegistryConfig { '' }  # No config = forces fallback paths
    }

    Context 'When SMB path is configured and upload succeeds' {
        It 'Should deliver via SMB and not attempt SMTP or Local Cache' {
            Mock Get-RegistryConfig { '\\server\share' } -ParameterFilter { $ValueName -eq 'SmbPath' }
            Mock Invoke-SmbUpload   { $true }
            Mock Invoke-SmtpDelivery { $false }
            Mock Invoke-LocalCache  { $false }

            Send-PatchReport -ReportJson '{}'

            Should -Invoke Invoke-SmbUpload   -Times 1
            Should -Invoke Invoke-SmtpDelivery -Times 0
            Should -Invoke Invoke-LocalCache   -Times 0
        }
    }

    Context 'When SMB upload fails and SMTP is configured and succeeds' {
        It 'Should fall back to SMTP and not write to Local Cache' {
            Mock Invoke-SmbUpload    { $false }
            Mock Get-RegistryConfig  { 'smtp.corp.local' } -ParameterFilter { $ValueName -eq 'SmtpServer' }
            Mock Get-RegistryConfig  { 'ops@corp.local'  } -ParameterFilter { $ValueName -eq 'SmtpTo' }
            Mock Invoke-SmtpDelivery { $true }
            Mock Invoke-LocalCache   { $false }

            Send-PatchReport -ReportJson '{}'

            Should -Invoke Invoke-SmbUpload    -Times 1
            Should -Invoke Invoke-SmtpDelivery -Times 1
            Should -Invoke Invoke-LocalCache   -Times 0
        }
    }

    Context 'When both SMB and SMTP fail' {
        It 'Should write report to Local Cache as last resort' {
            Mock Invoke-SmbUpload    { $false }
            Mock Invoke-SmtpDelivery { $false }
            Mock Invoke-LocalCache   { $true }

            Send-PatchReport -ReportJson '{}'

            Should -Invoke Invoke-LocalCache -Times 1
        }
    }

    Context 'When -SimulateSmbFailure is active' {
        It 'Should bypass SMB and attempt SMTP first' {
            $Script:SimulateSmbFailure = $true

            Mock Invoke-SmbUpload    { $false }
            Mock Invoke-SmtpDelivery { $true }
            Mock Invoke-LocalCache   { $false }

            Send-PatchReport -ReportJson '{}'

            Should -Invoke Invoke-SmbUpload   -Times 0
            Should -Invoke Invoke-SmtpDelivery -Times 1

            $Script:SimulateSmbFailure = $false
        }
    }
}

#endregion

#region --- Test: State File Safety ---

Describe 'Read-StateFile - Corruption Safety' -Tag 'Unit' {

    BeforeEach {
        Mock Write-AgentLog { }
    }

    Context 'When the state file does not exist' {
        It 'Should return an empty array without error' {
            Mock Test-Path { $false }

            $Result = Read-StateFile -FilePath 'C:\nonexistent\state.json'

            $Result | Should -BeOfType [array]
            $Result.Count | Should -Be 0
        }
    }

    Context 'When the state file contains invalid JSON' {
        It 'Should archive the corrupt file and return an empty array' {
            $TempFile = Join-Path $env:TEMP 'psa_test_corrupt.json'
            '{ this is not valid json' | Out-File -FilePath $TempFile -Encoding UTF8 -Force

            Mock Write-AgentLog { }
            Mock Rename-Item    { }

            $Result = Read-StateFile -FilePath $TempFile

            $Result.Count | Should -Be 0
            Should -Invoke Rename-Item -Times 1

            Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'When the state file contains valid JSON' {
        It 'Should parse and return the hotfix array' {
            $TempFile = Join-Path $env:TEMP 'psa_test_valid.json'
            @([PSCustomObject]@{ kb_id = 'KB1234567'; installed_on = '2026-01-01' }) |
                ConvertTo-Json | Out-File -FilePath $TempFile -Encoding UTF8 -Force

            $Result = Read-StateFile -FilePath $TempFile

            $Result.Count        | Should -BeGreaterThan 0
            $Result[0].kb_id     | Should -Be 'KB1234567'

            Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region --- Test: Idempotency ---

Describe 'Initialize-Environment - Self-Healing Directory Provisioning' -Tag 'Unit' {

    It 'Should create all required directories if they are missing' {
        Mock Test-Path  { $false } # Simulate all paths missing
        Mock New-Item   { } # Capture creation calls
        Mock Write-AgentLog { }

        Initialize-Environment

        # Expect 4 directories to be created: root, Logs, State, undelivered
        Should -Invoke New-Item -Times 4
    }

    It 'Should NOT recreate directories that already exist' {
        Mock Test-Path  { $true } # All paths exist
        Mock New-Item   { }
        Mock Write-AgentLog { }

        Initialize-Environment

        Should -Invoke New-Item -Times 0
    }
}

#endregion
