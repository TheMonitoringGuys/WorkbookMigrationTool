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

Describe 'Preflight in revert mode' {

    BeforeEach {
        Mock Test-DestinationWritable -ModuleName WorkbookScope.Preflight {
            [PSCustomObject]@{ Writable = 'Unknown'; Message = 'Write access was not probed.' }
        }
        # The source workspace has been deleted; the destination is still there.
        Mock Test-WorkspaceReachable -ModuleName WorkbookScope.Preflight {
            if ($WorkspaceName -eq 'src') {
                [PSCustomObject]@{ Reachable = $false; Location = $null; CustomerId = $null; ResourceId = '/src'; Message = "Workspace 'src' was not found." }
            }
            else {
                [PSCustomObject]@{ Reachable = $true; Location = 'eastus'; CustomerId = 'dst-guid'; ResourceId = '/dst'; Message = 'ok' }
            }
        }
    }

    It 'lets a revert proceed when the source workspace has been deleted' {
        # The bug this guards: reverting is what an operator does *because* the
        # source is going away, and revert reads nothing from it - yet preflight
        # failed the run with exit 2. The same run with -SkipPreflight reverted
        # every workbook successfully, so preflight was refusing work that would
        # have succeeded and pushing operators onto a flag that also disables the
        # destination checks.
        $result = Invoke-ScopePreflight -ArmEndpoint 'https://management.azure.com' `
            -SourceConfig (New-WorkspaceConfig -SubscriptionId 'sub-a' -ResourceGroupName 'rg-src' -WorkspaceName 'src') `
            -DestinationConfig (New-WorkspaceConfig -SubscriptionId 'sub-a' -ResourceGroupName 'rg-dst' -WorkspaceName 'dst') `
            -ThrottleDelayMs 0 -IsRevert

        $result.Passed | Should -BeTrue
        ($result.Errors -join "`n") | Should -Not -Match 'Source workspace'
        ($result.Warnings -join "`n") | Should -Match 'expected when reverting'
    }

    It 'still refuses to apply scope when the source workspace has been deleted' {
        # The other half of the contract: you cannot point a workbook at a
        # workspace that is not there, so applying scope must still fail.
        $result = Invoke-ScopePreflight -ArmEndpoint 'https://management.azure.com' `
            -SourceConfig (New-WorkspaceConfig -SubscriptionId 'sub-a' -ResourceGroupName 'rg-src' -WorkspaceName 'src') `
            -DestinationConfig (New-WorkspaceConfig -SubscriptionId 'sub-a' -ResourceGroupName 'rg-dst' -WorkspaceName 'dst') `
            -ThrottleDelayMs 0

        $result.Passed | Should -BeFalse
        ($result.Errors -join "`n") | Should -Match 'Source workspace is not reachable'
    }

    It 'still blocks when the destination is unreachable, even reverting' {
        # The destination holds the workbooks being read and written, so its
        # absence is blocking in every mode.
        Mock Test-WorkspaceReachable -ModuleName WorkbookScope.Preflight {
            [PSCustomObject]@{ Reachable = $false; Location = $null; CustomerId = $null; ResourceId = '/x'; Message = 'not found' }
        }

        $result = Invoke-ScopePreflight -ArmEndpoint 'https://management.azure.com' `
            -SourceConfig (New-WorkspaceConfig -SubscriptionId 'sub-a' -ResourceGroupName 'rg-src' -WorkspaceName 'src') `
            -DestinationConfig (New-WorkspaceConfig -SubscriptionId 'sub-a' -ResourceGroupName 'rg-dst' -WorkspaceName 'dst') `
            -ThrottleDelayMs 0 -IsRevert

        $result.Passed | Should -BeFalse
        ($result.Errors -join "`n") | Should -Match 'Destination workspace is not reachable'
    }
}
