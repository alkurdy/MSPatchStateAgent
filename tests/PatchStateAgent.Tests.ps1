# Pester unit tests for PatchStateAgent (PSA) - backward compatible with Pester v3/v4/v5

$global:PatchStateAgentTestMode = $true

$AgentScript = Join-Path $PSScriptRoot '..\src\PatchStateAgent.ps1'

if (-not (Test-Path $AgentScript)) {
    throw "Agent script not found at: $AgentScript"
}

Describe 'Compare-PatchState - Diff Engine' -Tag 'Unit' {
    BeforeAll {
        . $AgentScript -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Write-AgentLog { param($Level, $Message) }
        Mock Get-RegistryConfig { param($ValueName, $DefaultValue) return $DefaultValue }
    }

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

            $Added = @($Report.diff | Where-Object { $_.action -eq 'added' })
            @($Added).Count        | Should Be 1
            $Added[0].kb_id        | Should Be 'KB5034123'
            $Added[0].action       | Should Be 'added'
            $Report.summary.added  | Should Be 1
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

            $Removed = @($Report.diff | Where-Object { $_.action -eq 'removed' })
            @($Removed).Count        | Should Be 1
            $Removed[0].kb_id        | Should Be 'KB4000099'
            $Removed[0].action       | Should Be 'removed'
            $Report.summary.removed  | Should Be 1
        }
    }

    Context 'When current and previous states are identical' {
        It 'Should return an empty diff with summary added=0 removed=0' {
            $State = @(
                [PSCustomObject]@{ kb_id = 'KB1000001'; installed_on = '2026-01-01' },
                [PSCustomObject]@{ kb_id = 'KB2000002'; installed_on = '2026-02-14' }
            )

            $Report = Compare-PatchState -CurrentState $State -PreviousState $State

            @($Report.diff).Count    | Should Be 0
            $Report.summary.added    | Should Be 0
            $Report.summary.removed  | Should Be 0
        }
    }

    Context 'When previous state is empty (first run)' {
        It 'Should report all current KBs as [added]' {
            $Current = @(
                [PSCustomObject]@{ kb_id = 'KB1111111'; installed_on = '2026-05-01' },
                [PSCustomObject]@{ kb_id = 'KB2222222'; installed_on = '2026-05-02' }
            )

            $Report = Compare-PatchState -CurrentState $Current -PreviousState @()

            $Report.summary.added    | Should Be 2
            $Report.summary.removed  | Should Be 0
        }
    }

    Context 'When both states have mixed changes' {
        It 'Should correctly identify both added and removed KBs simultaneously' {
            $Previous = @(
                [PSCustomObject]@{ kb_id = 'KB1000001'; installed_on = '2026-01-01' },
                [PSCustomObject]@{ kb_id = 'KB9999999'; installed_on = '2026-01-01' }
            )
            $Current = @(
                [PSCustomObject]@{ kb_id = 'KB1000001'; installed_on = '2026-01-01' },
                [PSCustomObject]@{ kb_id = 'KB5034123'; installed_on = '2026-06-04' }
            )

            $Report = Compare-PatchState -CurrentState $Current -PreviousState $Previous

            $Report.summary.added    | Should Be 1
            $Report.summary.removed  | Should Be 1

            @($Report.diff | Where-Object { $_.kb_id -eq 'KB5034123' })[0].action | Should Be 'added'
            @($Report.diff | Where-Object { $_.kb_id -eq 'KB9999999' })[0].action | Should Be 'removed'
        }
    }

    Context 'Report payload structure' {
        It 'Should include required top-level fields' {
            $Report = Compare-PatchState -CurrentState @() -PreviousState @()

            $Report.timestamp       | Should Not BeNullOrEmpty
            $Report.computer_name   | Should Not BeNullOrEmpty
            ($Report.PSObject.Properties.Name -contains 'tag') | Should Be $true
            ($Report.PSObject.Properties.Name -contains 'orchestrator_override') | Should Be $true
            ($Report.PSObject.Properties.Name -contains 'summary') | Should Be $true
            ($Report.PSObject.Properties.Name -contains 'diff') | Should Be $true
        }
    }
}

Describe 'Test-OrchestratorOverride - Semaphore Check' -Tag 'Unit' {
    BeforeAll {
        . $AgentScript -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $global:OverridePathExists = $true
        $global:OverrideRegistryValue = 0

        Mock Test-PathExists { return $global:OverridePathExists }
        Mock Get-RegistryValue { param($Path, $Name) return $global:OverrideRegistryValue }
        Mock Set-RegistryValue { param($Path, $Name, $Value, $Type) }
        Mock Write-AgentLog { param($Level, $Message) }
    }

    Context 'When the OrchestratorTriggered registry value is 1' {
        It 'Should return $true and reset the flag to 0' {
            $global:OverridePathExists = $true
            $global:OverrideRegistryValue = 1

            $Result = Test-OrchestratorOverride

            $Result | Should Be $true
            Assert-MockCalled Set-RegistryValue -Times 1 -Scope It -ParameterFilter { $Value -eq 0 -and $Name -eq 'OrchestratorTriggered' }
        }
    }

    Context 'When the OrchestratorTriggered registry value is 0' {
        It 'Should return $false and not reset anything' {
            $global:OverridePathExists = $true
            $global:OverrideRegistryValue = 0

            $Result = Test-OrchestratorOverride

            $Result | Should Be $false
            Assert-MockCalled Set-RegistryValue -Times 0 -Scope It
        }
    }

    Context 'When the registry key does not exist' {
        It 'Should return $false gracefully' {
            $global:OverridePathExists = $false

            $Result = Test-OrchestratorOverride

            $Result | Should Be $false
        }
    }
}

Describe 'Send-PatchReport - Cascading Transport' -Tag 'Unit' {
    BeforeAll {
        . $AgentScript -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Write-AgentLog   { param($Level, $Message) }
        Mock Get-RegistryConfig { param($ValueName, $DefaultValue) return $DefaultValue }
    }

    Context 'When SMB path is configured and upload succeeds' {
        It 'Should deliver via SMB and not attempt SMTP or Local Cache' {
            Mock Get-RegistryConfig { param($ValueName, $DefaultValue)
                if ($ValueName -eq 'SmbPath') { return '\\server\share' }
                return $DefaultValue
            }
            Mock Invoke-SmbUpload   { param($ReportJson, $FileName) return $true }
            Mock Invoke-SmtpDelivery { param($ReportJson, $FileName) return $false }
            Mock Invoke-LocalCache  { param($ReportJson, $FileName) return $false }

            Send-PatchReport -ReportJson '{}'

            Assert-MockCalled Invoke-SmbUpload   -Times 1
            Assert-MockCalled Invoke-SmtpDelivery -Times 0
            Assert-MockCalled Invoke-LocalCache   -Times 0
        }
    }

    Context 'When SMB upload fails and SMTP is configured and succeeds' {
        It 'Should fall back to SMTP and not write to Local Cache' {
            Mock Get-RegistryConfig { param($ValueName, $DefaultValue)
                if ($ValueName -eq 'SmtpServer') { return 'smtp.corp.local' }
                if ($ValueName -eq 'SmtpTo') { return 'ops@corp.local' }
                return $DefaultValue
            }
            Mock Invoke-SmbUpload    { param($ReportJson, $FileName) return $false }
            Mock Invoke-SmtpDelivery { param($ReportJson, $FileName) return $true }
            Mock Invoke-LocalCache   { param($ReportJson, $FileName) return $false }

            Send-PatchReport -ReportJson '{}'

            Assert-MockCalled Invoke-SmbUpload    -Times 1
            Assert-MockCalled Invoke-SmtpDelivery -Times 1
            Assert-MockCalled Invoke-LocalCache   -Times 0
        }
    }

    Context 'When both SMB and SMTP fail' {
        It 'Should write report to Local Cache as last resort' {
            Mock Invoke-SmbUpload    { param($ReportJson, $FileName) return $false }
            Mock Invoke-SmtpDelivery { param($ReportJson, $FileName) return $false }
            Mock Invoke-LocalCache   { param($ReportJson, $FileName) return $true }

            Send-PatchReport -ReportJson '{}'

            Assert-MockCalled Invoke-LocalCache -Times 1
        }
    }

    Context 'When -SimulateSmbFailure is active' {
        It 'Should bypass SMB and attempt SMTP first' {
            $Script:SimulateSmbFailure = $true

            Mock Invoke-SmbUpload    { param($ReportJson, $FileName) return $false }
            Mock Invoke-SmtpDelivery { param($ReportJson, $FileName) return $true }
            Mock Invoke-LocalCache   { param($ReportJson, $FileName) return $false }

            Send-PatchReport -ReportJson '{}'

            Assert-MockCalled Invoke-SmbUpload   -Times 0
            Assert-MockCalled Invoke-SmtpDelivery -Times 1

            $Script:SimulateSmbFailure = $false
        }
    }
}

Describe 'Read-StateFile - Corruption Safety' -Tag 'Unit' {
    BeforeAll {
        . $AgentScript -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Write-AgentLog { param($Level, $Message) }
    }

    Context 'When the state file does not exist' {
        It 'Should return an empty array without error' {
            Mock Test-Path { return $false }

            $Result = Read-StateFile -FilePath 'C:\nonexistent\state.json'

            ($Result -is [System.Array]) | Should Be $true
            @($Result).Count | Should Be 0
        }
    }

    Context 'When the state file contains invalid JSON' {
        It 'Should archive the corrupt file and return an empty array' {
            $TempFile = Join-Path $env:TEMP 'psa_test_corrupt.json'
            '{ this is not valid json' | Out-File -FilePath $TempFile -Encoding UTF8 -Force

            Mock Test-Path   { return $true }
            Mock Rename-Item { }

            $Result = Read-StateFile -FilePath $TempFile

            @($Result).Count | Should Be 0
            Assert-MockCalled Rename-Item -Times 1

            Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'When the state file contains valid JSON' {
        It 'Should parse and return the hotfix array' {
            $TempFile = Join-Path $env:TEMP 'psa_test_valid.json'
            @([PSCustomObject]@{ kb_id = 'KB1234567'; installed_on = '2026-01-01' }) |
                ConvertTo-Json | Out-File -FilePath $TempFile -Encoding UTF8 -Force

            Mock Test-Path { return $true }

            $Result = Read-StateFile -FilePath $TempFile

            @($Result).Count     | Should BeGreaterThan 0
            $Result[0].kb_id     | Should Be 'KB1234567'

            Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Initialize-Environment - Self-Healing Directory Provisioning' -Tag 'Unit' {
    BeforeAll {
        . $AgentScript -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $global:InitPathExists = $false
        Mock Test-PathExists { return $global:InitPathExists }
        Mock New-Directory { param($Path) }
        Mock Write-AgentLog { param($Level, $Message) }
    }

    It 'Should create all required directories if they are missing' {
        $global:InitPathExists = $false

        Initialize-Environment

        Assert-MockCalled New-Directory -Times 4 -Scope It
    }

    It 'Should NOT recreate directories that already exist' {
        $global:InitPathExists = $true

        Initialize-Environment

        Assert-MockCalled New-Directory -Times 0 -Scope It
    }
}
