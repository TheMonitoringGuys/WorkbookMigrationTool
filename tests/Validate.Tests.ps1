<#
    Tests for opt-in query validation.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Validate.psm1') -Force -DisableNameChecking

    $script:LogEndpoint = 'https://api.loganalytics.io'
    $script:ArmEndpoint = 'https://management.azure.com'
    $script:SourceCustomerId = '00000000-0000-0000-0000-000000000001'
    $script:DestinationCustomerId = '00000000-0000-0000-0000-000000000002'
    $script:SourceWorkspaceId = '/subscriptions/sub-src/resourceGroups/rg-src/providers/Microsoft.OperationalInsights/workspaces/ws-src'
    $script:SourceSubscriptionId = 'sub-src'
}

Describe 'Workspace query invocation' {

    BeforeEach {
        $script:CapturedBodies = [System.Collections.Generic.List[object]]::new()
    }

    It 'returns the first table rows on a normal response' {
        Mock Invoke-ScopeApi -ModuleName WorkbookScope.Validate {
            $script:CapturedBodies.Add($Body)
            [PSCustomObject]@{
                tables = @(
                    [PSCustomObject]@{ rows = @(@('SecurityEvent', 2), @('Heartbeat', 1)) },
                    [PSCustomObject]@{ rows = @(@('Ignored', 99)) }
                )
            }
        }

        $result = Invoke-WorkspaceQuery -LogAnalyticsEndpoint $script:LogEndpoint `
            -WorkspaceCustomerId $script:DestinationCustomerId -Query 'Heartbeat | take 1' -ThrottleDelayMs 0

        $result.Success | Should -BeTrue
        @($result.Rows).Count | Should -Be 2
        $result.Rows[0][0] | Should -Be 'SecurityEvent'
        $result.Error | Should -BeNullOrEmpty
    }

    It 'returns a finding-shaped failure when the call throws' {
        Mock Invoke-ScopeApi -ModuleName WorkbookScope.Validate { throw 'query exploded' }

        $result = Invoke-WorkspaceQuery -LogAnalyticsEndpoint $script:LogEndpoint `
            -WorkspaceCustomerId $script:DestinationCustomerId -Query 'Heartbeat | take 1' -ThrottleDelayMs 0

        $result.Success | Should -BeFalse
        @($result.Rows).Count | Should -Be 0
        $result.Error | Should -Match 'query exploded'
    }

    It 'adds workspaces to the request body only when additional workspaces are supplied' {
        Mock Invoke-ScopeApi -ModuleName WorkbookScope.Validate {
            $script:CapturedBodies.Add($Body)
            [PSCustomObject]@{ tables = @([PSCustomObject]@{ rows = @() }) }
        }

        $null = Invoke-WorkspaceQuery -LogAnalyticsEndpoint $script:LogEndpoint `
            -WorkspaceCustomerId $script:DestinationCustomerId -Query 'print x = 1' -ThrottleDelayMs 0
        $null = Invoke-WorkspaceQuery -LogAnalyticsEndpoint $script:LogEndpoint `
            -WorkspaceCustomerId $script:DestinationCustomerId -Query 'print x = 1' `
            -AdditionalWorkspaceIds @($script:SourceWorkspaceId) -ThrottleDelayMs 0

        $script:CapturedBodies[0].ContainsKey('workspaces') | Should -BeFalse
        $script:CapturedBodies[1].ContainsKey('workspaces') | Should -BeTrue
        @($script:CapturedBodies[1]['workspaces']).Count | Should -Be 1
        $script:CapturedBodies[1]['workspaces'][0] | Should -Be $script:SourceWorkspaceId
    }
}

Describe 'Workspace table inventory' {

    It 'extracts table names from returned rows' {
        Mock Invoke-WorkspaceQuery -ModuleName WorkbookScope.Validate {
            [PSCustomObject]@{
                Success = $true
                Rows    = @(@('SecurityEvent'), @('Heartbeat'), @(''))
                Error   = $null
            }
        }

        $result = Get-WorkspaceTableInventory -LogAnalyticsEndpoint $script:LogEndpoint `
            -WorkspaceCustomerId $script:SourceCustomerId -ThrottleDelayMs 0

        $result.Success | Should -BeTrue
        $result.Tables | Should -Be @('SecurityEvent', 'Heartbeat')
        $result.Error | Should -BeNullOrEmpty
    }

    It 'reports inventory failure instead of making the workspace look empty' {
        Mock Invoke-WorkspaceQuery -ModuleName WorkbookScope.Validate {
            [PSCustomObject]@{ Success = $false; Rows = @(); Error = 'Usage table denied' }
        }

        $result = Get-WorkspaceTableInventory -LogAnalyticsEndpoint $script:LogEndpoint `
            -WorkspaceCustomerId $script:SourceCustomerId -ThrottleDelayMs 0

        $result.Success | Should -BeFalse
        @($result.Tables).Count | Should -Be 0
        $result.Error | Should -Match 'Usage table denied'
    }
}

Describe 'Cross-workspace access probe' {

    BeforeEach {
        $script:CapturedQueries = [System.Collections.Generic.List[string]]::new()
    }

    It 'succeeds when the probe query returns' {
        Mock Invoke-WorkspaceQuery -ModuleName WorkbookScope.Validate {
            $script:CapturedQueries.Add($Query)
            [PSCustomObject]@{ Success = $true; Rows = @(@(1)); Error = $null }
        }

        $result = Test-CrossWorkspaceAccess -LogAnalyticsEndpoint $script:LogEndpoint `
            -DestinationCustomerId $script:DestinationCustomerId `
            -SourceWorkspaceResourceId $script:SourceWorkspaceId -ThrottleDelayMs 0

        $result.Ok | Should -BeTrue
        $result.Error | Should -BeNullOrEmpty
        $script:CapturedQueries[0] | Should -Be 'print probe = 1'
    }

    It 'adds a viewer-facing Log Analytics Reader hint on permission-shaped failures' {
        Mock Invoke-WorkspaceQuery -ModuleName WorkbookScope.Validate {
            [PSCustomObject]@{ Success = $false; Rows = @(); Error = 'Forbidden: caller does not have access' }
        }

        $result = Test-CrossWorkspaceAccess -LogAnalyticsEndpoint $script:LogEndpoint `
            -DestinationCustomerId $script:DestinationCustomerId `
            -SourceWorkspaceResourceId $script:SourceWorkspaceId -ThrottleDelayMs 0

        $result.Ok | Should -BeFalse
        $result.Error | Should -Match 'Log Analytics Reader'
        $result.Error | Should -Match 'source workspace'
        $result.Error | Should -Match 'view'
    }
}

Describe 'Self-healing scope parameter probe' {

    It 'resolves when Resource Graph returns the source workspace' {
        Mock Invoke-ScopeApi -ModuleName WorkbookScope.Validate {
            [PSCustomObject]@{ data = @([PSCustomObject]@{ value = $script:SourceWorkspaceId }) }
        }

        $result = Test-ScopeParameterResolves -ArmEndpoint $script:ArmEndpoint `
            -SourceWorkspaceId $script:SourceWorkspaceId `
            -SourceSubscriptionId $script:SourceSubscriptionId -ThrottleDelayMs 0

        $result.Resolves | Should -BeTrue
        $result.Skipped | Should -BeFalse
        $result.Reason | Should -BeNullOrEmpty
    }

    It 'reports the silent destination-only degradation when Resource Graph returns nothing' {
        Mock Invoke-ScopeApi -ModuleName WorkbookScope.Validate {
            [PSCustomObject]@{ data = @() }
        }

        $result = Test-ScopeParameterResolves -ArmEndpoint $script:ArmEndpoint `
            -SourceWorkspaceId $script:SourceWorkspaceId `
            -SourceSubscriptionId $script:SourceSubscriptionId -ThrottleDelayMs 0

        $result.Resolves | Should -BeFalse
        $result.Skipped | Should -BeFalse
        $result.Reason | Should -Match 'Resource Graph'
        $result.Reason | Should -Match 'source workspace'
        $result.Reason | Should -Match 'destination-only'
    }

    It 'skips rather than reporting a false negative when no subscription id is available' {
        $result = Test-ScopeParameterResolves -ArmEndpoint $script:ArmEndpoint `
            -SourceWorkspaceId $script:SourceWorkspaceId -ThrottleDelayMs 0

        $result.Resolves | Should -BeFalse
        $result.Skipped | Should -BeTrue
        $result.Reason | Should -Match 'no source subscription id'
    }

    It 'returns a validation finding when the Resource Graph call throws' {
        Mock Invoke-ScopeApi -ModuleName WorkbookScope.Validate { throw 'Unauthorized to query Resource Graph' }

        { $script:ScopeParameterFailure = Test-ScopeParameterResolves -ArmEndpoint $script:ArmEndpoint `
                -SourceWorkspaceId $script:SourceWorkspaceId `
                -SourceSubscriptionId $script:SourceSubscriptionId -ThrottleDelayMs 0 } | Should -Not -Throw

        $script:ScopeParameterFailure.Resolves | Should -BeFalse
        $script:ScopeParameterFailure.Skipped | Should -BeFalse
        $script:ScopeParameterFailure.Reason | Should -Match 'Resource Graph visibility'
    }
}

Describe 'Scope validation result' {

    BeforeEach {
        $script:InventoryByCustomerId = @{}
        Mock Test-CrossWorkspaceAccess -ModuleName WorkbookScope.Validate {
            [PSCustomObject]@{ Ok = $true; Error = $null }
        }
        Mock Test-ScopeParameterResolves -ModuleName WorkbookScope.Validate {
            [PSCustomObject]@{ Resolves = $true; Reason = $null; Skipped = $false }
        }
        Mock Get-WorkspaceTableInventory -ModuleName WorkbookScope.Validate {
            $script:InventoryByCustomerId[$WorkspaceCustomerId]
        }
    }

    It 'populates the self-healing scope parameter status' {
        $script:InventoryByCustomerId[$script:SourceCustomerId] = [PSCustomObject]@{ Success = $true; Tables = @('Heartbeat'); Error = $null }
        $script:InventoryByCustomerId[$script:DestinationCustomerId] = [PSCustomObject]@{ Success = $true; Tables = @('Heartbeat'); Error = $null }

        $result = Invoke-ScopeValidation -LogAnalyticsEndpoint $script:LogEndpoint `
            -SourceCustomerId $script:SourceCustomerId -DestinationCustomerId $script:DestinationCustomerId `
            -SourceWorkspaceResourceId $script:SourceWorkspaceId -Workbooks @() `
            -ScopeMode SelfHealing -SourceSubscriptionId $script:SourceSubscriptionId `
            -ArmEndpoint $script:ArmEndpoint -ThrottleDelayMs 0

        $result.ScopeParameterResolves | Should -BeTrue
        $result.ScopeParameterError | Should -BeNullOrEmpty
        Should -Invoke Test-ScopeParameterResolves -ModuleName WorkbookScope.Validate -Times 1 -Exactly
    }

    It 'does not run the scope parameter probe in literal mode' {
        $script:InventoryByCustomerId[$script:SourceCustomerId] = [PSCustomObject]@{ Success = $true; Tables = @('Heartbeat'); Error = $null }
        $script:InventoryByCustomerId[$script:DestinationCustomerId] = [PSCustomObject]@{ Success = $true; Tables = @('Heartbeat'); Error = $null }

        $result = Invoke-ScopeValidation -LogAnalyticsEndpoint $script:LogEndpoint `
            -SourceCustomerId $script:SourceCustomerId -DestinationCustomerId $script:DestinationCustomerId `
            -SourceWorkspaceResourceId $script:SourceWorkspaceId -Workbooks @() `
            -ScopeMode Literal -ArmEndpoint $script:ArmEndpoint -ThrottleDelayMs 0

        $result.ScopeParameterResolves | Should -BeNullOrEmpty
        $result.ScopeParameterError | Should -BeNullOrEmpty
        Should -Invoke Test-ScopeParameterResolves -ModuleName WorkbookScope.Validate -Times 0 -Exactly
    }

    It 'computes table differences case-insensitively' {
        $script:InventoryByCustomerId[$script:SourceCustomerId] = [PSCustomObject]@{
            Success = $true
            Tables  = @('SecurityEvent', 'Heartbeat')
            Error   = $null
        }
        $script:InventoryByCustomerId[$script:DestinationCustomerId] = [PSCustomObject]@{
            Success = $true
            Tables  = @('securityevent', 'SigninLogs')
            Error   = $null
        }

        $result = Invoke-ScopeValidation -LogAnalyticsEndpoint $script:LogEndpoint `
            -SourceCustomerId $script:SourceCustomerId -DestinationCustomerId $script:DestinationCustomerId `
            -SourceWorkspaceResourceId $script:SourceWorkspaceId -Workbooks @(
                [PSCustomObject]@{ DisplayName = 'Workbook A'; Tables = @('Heartbeat', 'SigninLogs', 'MissingBoth') }
            ) -ScopeMode Literal -ThrottleDelayMs 0

        $result.OnlyInSource | Should -Be @('Heartbeat')
        $result.OnlyInDestination | Should -Be @('SigninLogs')
        @($result.WorkbookFindings).Count | Should -Be 1
        $result.WorkbookFindings[0].MissingInDestination | Should -Be @('Heartbeat')
        $result.WorkbookFindings[0].MissingInSource | Should -Be @('SigninLogs')
    }

    It 'leaves table differences empty when either inventory failed' {
        $script:InventoryByCustomerId[$script:SourceCustomerId] = [PSCustomObject]@{ Success = $false; Tables = @(); Error = 'source denied' }
        $script:InventoryByCustomerId[$script:DestinationCustomerId] = [PSCustomObject]@{ Success = $true; Tables = @('Heartbeat'); Error = $null }

        $result = Invoke-ScopeValidation -LogAnalyticsEndpoint $script:LogEndpoint `
            -SourceCustomerId $script:SourceCustomerId -DestinationCustomerId $script:DestinationCustomerId `
            -SourceWorkspaceResourceId $script:SourceWorkspaceId -Workbooks @(
                [PSCustomObject]@{ DisplayName = 'Workbook A'; Tables = @('Heartbeat') }
            ) -ScopeMode Literal -ThrottleDelayMs 0

        @($result.OnlyInSource).Count | Should -Be 0
        @($result.OnlyInDestination).Count | Should -Be 0
        @($result.WorkbookFindings).Count | Should -Be 0
    }

    It 'returns the complete result shape for zero workbooks' {
        $script:InventoryByCustomerId[$script:SourceCustomerId] = [PSCustomObject]@{ Success = $true; Tables = @(); Error = $null }
        $script:InventoryByCustomerId[$script:DestinationCustomerId] = [PSCustomObject]@{ Success = $true; Tables = @(); Error = $null }

        { $script:EmptyValidation = Invoke-ScopeValidation -LogAnalyticsEndpoint $script:LogEndpoint `
                -SourceCustomerId $script:SourceCustomerId -DestinationCustomerId $script:DestinationCustomerId `
                -SourceWorkspaceResourceId $script:SourceWorkspaceId -Workbooks @() `
                -ScopeMode Literal -ThrottleDelayMs 0 } | Should -Not -Throw

        foreach ($name in @('SourceTables', 'DestinationTables', 'OnlyInSource', 'OnlyInDestination',
                'CrossQueryOk', 'CrossQueryError', 'ScopeParameterResolves', 'ScopeParameterError', 'WorkbookFindings')) {
            $script:EmptyValidation.PSObject.Properties.Name | Should -Contain $name
        }
        $script:EmptyValidation.CrossQueryOk | Should -BeTrue
        @($script:EmptyValidation.WorkbookFindings).Count | Should -Be 0
    }
}
