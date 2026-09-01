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

Describe 'Access token validation' {
    <#
        A malformed Authorization header does not surface as a clean 401. Azure
        answers with HTTP 502 and "Forbidden: Authentication information is not
        given in the correct format", which reads like a permissions problem and
        costs real time to trace back to the client. Each case below is a way that
        header has actually been produced, and each must fail here - locally, with
        a message naming the fix - rather than at Azure.
    #>

    BeforeAll {
        # A structurally valid JWT. Content is irrelevant; only the shape is checked.
        $script:GoodToken = 'eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJodHRwczovL21hbmFnZW1lbnQuYXp1cmUuY29tIn0.c2lnbmF0dXJl'
    }

    It 'accepts a well-formed bearer token' {
        { Assert-ScopeTokenUsable -Token $script:GoodToken -ResourceUrl 'https://management.azure.com' } |
            Should -Not -Throw
    }

    It 'rejects an empty token and points at the expired session' {
        # An expired device-code session hands back nothing, producing a bare
        # "Bearer " header.
        { Assert-ScopeTokenUsable -Token '' -ResourceUrl 'https://management.azure.com' } |
            Should -Throw '*session has probably expired*'
    }

    It 'names device auth in the reconnect advice' {
        # The tenants that hit this are the ones that mandate -UseDeviceAuth, so
        # the generic "Connect-AzAccount" alone would not be enough to act on.
        { Assert-ScopeTokenUsable -Token '' -ResourceUrl 'https://management.azure.com' } |
            Should -Throw '*-UseDeviceAuth*'
    }

    It 'rejects an unconverted SecureString' {
        # Az.Accounts 5.x returns a SecureString. Missing the conversion yields the
        # literal type name in the header.
        { Assert-ScopeTokenUsable -Token 'System.Security.SecureString' -ResourceUrl 'https://management.azure.com' } |
            Should -Throw '*Az.Accounts*'
    }

    It 'rejects a token containing whitespace and names multiple contexts' {
        # Two tokens joined by string interpolation - what happens when
        # Get-AzAccessToken emits more than one object.
        $joined = "$($script:GoodToken) $($script:GoodToken)"
        { Assert-ScopeTokenUsable -Token $joined -ResourceUrl 'https://management.azure.com' } |
            Should -Throw '*more than one object*'
    }

    It 'rejects a value that is not a JWT without echoing the whole value' {
        { Assert-ScopeTokenUsable -Token 'not-a-token-at-all' -ResourceUrl 'https://management.azure.com' } |
            Should -Throw '*is not a bearer token*'
    }

    It 'truncates the preview so a token is never written out in full' {
        # The preview exists to identify the value, not to disclose it. A real
        # token must never reach a log or a support ticket through this path.
        $long = 'X' * 400
        $err = $null
        try { Assert-ScopeTokenUsable -Token $long -ResourceUrl 'https://management.azure.com' }
        catch { $err = $_.Exception.Message }

        $err | Should -Not -BeNullOrEmpty
        $err | Should -Not -Match ('X' * 20)
        $err | Should -Match 'length 400'
    }
}
