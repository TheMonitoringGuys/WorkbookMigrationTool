<#
    Tests for preflight checks.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Preflight.psm1') -Force -DisableNameChecking

    function New-WorkspaceConfig {
        param([string]$SubscriptionId, [string]$ResourceGroupName, [string]$WorkspaceName)
        [PSCustomObject]@{
            SubscriptionId    = $SubscriptionId
            ResourceGroupName = $ResourceGroupName
            WorkspaceName     = $WorkspaceName
        }
    }
}

Describe 'Prerequisite assertion' {

    BeforeEach {
        Mock Test-ScopeModulePresent -ModuleName WorkbookScope.Preflight { [version]'5.0.0' } -ParameterFilter { $Name -eq 'Az.Accounts' }
        Mock Get-Command -ModuleName WorkbookScope.Preflight { [PSCustomObject]@{ Name = 'Get-AzContext' } } -ParameterFilter { $Name -eq 'Get-AzContext' }
        Mock Get-AzContext -ModuleName WorkbookScope.Preflight {
            [PSCustomObject]@{ Account = [PSCustomObject]@{ Id = 'operator@example.com' } }
        }
    }

    It 'is silent when prerequisites are present' {
        $output = @(Assert-ScopePrerequisite)
        $output.Count | Should -Be 0
    }
}

Describe 'Workspace reachability' {

    It 'populates reachability details on success' {
        Mock Invoke-ScopeApi -ModuleName WorkbookScope.Preflight {
            [PSCustomObject]@{
                id         = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
                location   = 'eastus'
                properties = [PSCustomObject]@{ customerId = '00000000-0000-0000-0000-000000000001' }
            }
        }

        $result = Test-WorkspaceReachable -ArmEndpoint 'https://management.azure.com' -SubscriptionId 'sub' -ResourceGroupName 'rg' -WorkspaceName 'ws' -ThrottleDelayMs 0

        $result.Reachable | Should -BeTrue
        $result.Location | Should -Be 'eastus'
        $result.CustomerId | Should -Be '00000000-0000-0000-0000-000000000001'
    }

    It 'returns a distinct human-readable access denied message for 403' {
        Mock Invoke-ScopeApi -ModuleName WorkbookScope.Preflight { throw 'HTTP 403 on GET uri - AuthorizationFailed: denied' }

        $result = Test-WorkspaceReachable -ArmEndpoint 'https://management.azure.com' -SubscriptionId 'sub' -ResourceGroupName 'rg' -WorkspaceName 'ws' -ThrottleDelayMs 0

        $result.Reachable | Should -BeFalse
        $result.Message | Should -Match 'Access denied'
        $result.Message | Should -Match 'Reader'
    }

    It 'returns a distinct human-readable not found message for 404' {
        Mock Invoke-ScopeApi -ModuleName WorkbookScope.Preflight { throw 'HTTP 404 on GET uri - NotFound: missing' }

        $result = Test-WorkspaceReachable -ArmEndpoint 'https://management.azure.com' -SubscriptionId 'sub' -ResourceGroupName 'rg' -WorkspaceName 'ws' -ThrottleDelayMs 0

        $result.Reachable | Should -BeFalse
        $result.Message | Should -Match 'not found'
        $result.Message | Should -Match 'subscription, resource group and workspace name'
    }
}

Describe 'Preflight result' {

    BeforeEach {
        Mock Test-DestinationWritable -ModuleName WorkbookScope.Preflight {
            [PSCustomObject]@{ Writable = 'Unknown'; Message = 'Write access was not probed.' }
        }
    }

    It 'sets cross-subscription and cross-region warnings without failing' {
        Mock Test-WorkspaceReachable -ModuleName WorkbookScope.Preflight {
            if ($WorkspaceName -eq 'src') {
                [PSCustomObject]@{ Reachable = $true; Location = 'westus'; CustomerId = 'src-guid'; ResourceId = '/src'; Message = 'ok' }
            }
            else {
                [PSCustomObject]@{ Reachable = $true; Location = 'eastus'; CustomerId = 'dst-guid'; ResourceId = '/dst'; Message = 'ok' }
            }
        }

        $result = Invoke-ScopePreflight -ArmEndpoint 'https://management.azure.com' `
            -SourceConfig (New-WorkspaceConfig -SubscriptionId 'sub-a' -ResourceGroupName 'rg-src' -WorkspaceName 'src') `
            -DestinationConfig (New-WorkspaceConfig -SubscriptionId 'sub-b' -ResourceGroupName 'rg-dst' -WorkspaceName 'dst') `
            -ThrottleDelayMs 0

        $result.Passed | Should -BeTrue
        $result.CrossSubscription | Should -BeTrue
        $result.CrossRegion | Should -BeTrue
        ($result.Warnings -join "`n") | Should -Match 'different subscriptions'
        ($result.Warnings -join "`n") | Should -Match 'different regions'
    }

    It 'emits the Log Analytics Reader warning on every run' {
        Mock Test-WorkspaceReachable -ModuleName WorkbookScope.Preflight {
            [PSCustomObject]@{ Reachable = $true; Location = 'eastus'; CustomerId = 'guid'; ResourceId = '/id'; Message = 'ok' }
        }

        foreach ($i in 1..2) {
            $result = Invoke-ScopePreflight -ArmEndpoint 'https://management.azure.com' `
                -SourceConfig (New-WorkspaceConfig -SubscriptionId 'sub' -ResourceGroupName 'rg-src' -WorkspaceName 'src') `
                -DestinationConfig (New-WorkspaceConfig -SubscriptionId 'sub' -ResourceGroupName 'rg-dst' -WorkspaceName 'dst') `
                -ThrottleDelayMs 0

            $result.Passed | Should -BeTrue
            ($result.Warnings -join "`n") | Should -Match 'Log Analytics Reader'
        }
    }
}
