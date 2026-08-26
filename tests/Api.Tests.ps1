<#
    Tests for API URI builders and defaults.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Api.psm1') -Force -DisableNameChecking
}

Describe 'API versions' {

    It 'returns documented versions for known resources' {
        Get-ScopeApiVersion 'workbooks' | Should -Be '2022-04-01'
        Get-ScopeApiVersion 'workspaces' | Should -Be '2023-09-01'
        Get-ScopeApiVersion 'query' | Should -Be '2017-10-01'
    }

    It 'throws for an unknown resource name' {
        { Get-ScopeApiVersion 'widgets' } | Should -Throw '*Unknown API resource*'
    }
}

Describe 'Workspace URI builders' {

    BeforeAll {
        $script:Arm = 'https://management.azure.com'
        $script:Sub = '11111111-1111-1111-1111-111111111111'
        $script:Rg = 'rg-one'
        $script:Ws = 'ws-one'
    }

    It 'builds the bare workspace resource ID used by workbook scope fields' {
        $id = Get-WorkspaceResourceId -SubscriptionId $script:Sub -ResourceGroupName $script:Rg -WorkspaceName $script:Ws

        $id | Should -Be "/subscriptions/$($script:Sub)/resourceGroups/$($script:Rg)/providers/Microsoft.OperationalInsights/workspaces/$($script:Ws)"
        $id | Should -Not -Match '^https?://'
        $id | Should -Not -Match '\?'
    }

    It 'prefixes the ARM endpoint for a callable workspace URI' {
        Get-ScopeWorkspaceUri -ArmEndpoint $script:Arm -SubscriptionId $script:Sub -ResourceGroupName $script:Rg -WorkspaceName $script:Ws |
            Should -Be "$script:Arm/subscriptions/$script:Sub/resourceGroups/$script:Rg/providers/Microsoft.OperationalInsights/workspaces/$script:Ws"
    }

    It 'appends the workspace API version' {
        $uri = Get-ScopeWorkspaceUri -ArmEndpoint $script:Arm -SubscriptionId $script:Sub -ResourceGroupName $script:Rg -WorkspaceName $script:Ws
        Get-WorkspaceUriWithVersion -WorkspaceUri $uri | Should -Be "$uri`?api-version=2023-09-01"
    }
}

Describe 'Workbook and query URI builders' {

    BeforeAll {
        $script:Arm = 'https://management.azure.com'
        $script:Sub = '22222222-2222-2222-2222-222222222222'
        $script:Rg = 'rg-dest'
    }

    It 'builds the Sentinel workbook list URI and URL-encodes sourceId' {
        $sourceId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
        $uri = Get-WorkbooksUri -ArmEndpoint $script:Arm -SubscriptionId $script:Sub -ResourceGroupName $script:Rg -SourceId $sourceId

        $uri | Should -Match 'category=sentinel'
        $uri | Should -Match 'canFetchContent=true'
        $uri | Should -Match 'api-version=2022-04-01'
        $uri | Should -Match ([regex]::Escape([Uri]::EscapeDataString($sourceId)))
    }

    It 'builds a workbook item URI' {
        Get-WorkbookUri -ArmEndpoint $script:Arm -SubscriptionId $script:Sub -ResourceGroupName $script:Rg -WorkbookId 'wb1' |
            Should -Be "$script:Arm/subscriptions/$script:Sub/resourceGroups/$script:Rg/providers/Microsoft.Insights/workbooks/wb1?api-version=2022-04-01"
    }

    It 'builds a Log Analytics query URI' {
        Get-LogAnalyticsQueryUri -LogAnalyticsEndpoint 'https://api.loganalytics.io' -WorkspaceId 'customer-guid' |
            Should -Be 'https://api.loganalytics.io/v1/workspaces/customer-guid/query?api-version=2017-10-01'
    }
}

Describe 'API defaults' {

    It 'round-trips retry count and ignores negative values' {
        Set-ScopeApiDefault -RetryCount 5
        (Get-ScopeApiDefault).RetryCount | Should -Be 5

        Set-ScopeApiDefault -RetryCount -1
        (Get-ScopeApiDefault).RetryCount | Should -Be 5
    }
}
