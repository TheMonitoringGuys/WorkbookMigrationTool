<#
    Tests for destination workbook discovery and tag handling.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Discovery.psm1') -Force -DisableNameChecking

    function New-Workbook {
        param(
            [string]$Name = 'wb-resource',
            [object]$Tags = @{},
            [string]$DisplayName
        )

        [PSCustomObject]@{
            name       = $Name
            tags       = $Tags
            properties = [PSCustomObject]@{ displayName = $DisplayName }
        }
    }
}

Describe 'Migration tag detection' {

    It 'is true when a hashtable contains a non-empty migration tag' {
        Test-WorkbookIsMigrated (New-Workbook -Tags @{ MigratedFromWorkbookId = 'source-id' }) | Should -BeTrue
    }

    It 'is true when a PSCustomObject contains a non-empty migration tag' {
        Test-WorkbookIsMigrated (New-Workbook -Tags ([PSCustomObject]@{ MigratedFromWorkbookId = 'source-id' })) | Should -BeTrue
    }

    It 'is false when tags are null, empty, or the migration tag is blank' {
        Test-WorkbookIsMigrated (New-Workbook -Tags $null) | Should -BeFalse
        Test-WorkbookIsMigrated (New-Workbook -Tags @{}) | Should -BeFalse
        Test-WorkbookIsMigrated (New-Workbook -Tags @{ MigratedFromWorkbookId = '' }) | Should -BeFalse
    }
}

Describe 'Workbook display name' {

    It 'prefers properties.displayName' {
        Get-WorkbookDisplayName (New-Workbook -DisplayName 'Display' -Tags @{ 'hidden-title' = 'Hidden' } -Name 'Name') | Should -Be 'Display'
    }

    It 'falls back to the hidden-title tag' {
        Get-WorkbookDisplayName (New-Workbook -Tags @{ 'hidden-title' = 'Hidden' } -Name 'Name') | Should -Be 'Hidden'
    }

    It 'falls back to resource name and then a placeholder' {
        Get-WorkbookDisplayName (New-Workbook -Name 'Name') | Should -Be 'Name'
        Get-WorkbookDisplayName (New-Workbook -Name '') | Should -Not -BeNullOrEmpty
    }
}

Describe 'Scope tags' {

    It 'preserves existing hashtable tags while adding scope tags' {
        $tags = Get-WorkbookScopeTag -ExistingTags @{ owner = 'blue'; env = 'test' } -SourceWorkspaceName 'ws-source'

        $tags.owner | Should -Be 'blue'
        $tags.env | Should -Be 'test'
        $tags.DualScopeApplied | Should -Not -BeNullOrEmpty
        $tags.DualScopeSourceWorkspace | Should -Be 'ws-source'
        ([string]$tags.DualScopeSourceWorkspace).Length | Should -BeLessOrEqual 256
    }

    It 'preserves existing PSCustomObject tags while adding scope tags' {
        $tags = Get-WorkbookScopeTag -ExistingTags ([PSCustomObject]@{ owner = 'blue' }) -SourceWorkspaceName 'ws-source'

        $tags.owner | Should -Be 'blue'
        $tags.DualScopeSourceWorkspace | Should -Be 'ws-source'
    }

    It 'removes only this tool''s tags on revert' {
        $tags = Get-WorkbookScopeTag -ExistingTags @{
            owner                    = 'blue'
            DualScopeApplied         = 'yesterday'
            DualScopeSourceWorkspace = 'ws-source'
        } -SourceWorkspaceName 'unused' -Revert

        $tags.owner | Should -Be 'blue'
        $tags.ContainsKey('DualScopeApplied') | Should -BeFalse
        $tags.ContainsKey('DualScopeSourceWorkspace') | Should -BeFalse
    }
}

Describe 'Destination workbook filtering' {

    BeforeAll {
        $script:DiscoveryWorkbooks = @(
            (New-Workbook -Name 'one' -DisplayName 'Security Overview' -Tags @{ MigratedFromWorkbookId = 'src-1'; 'hidden-title' = 'Security Overview' }),
            (New-Workbook -Name 'two' -DisplayName 'Network Map' -Tags @{}),
            (New-Workbook -Name 'three' -DisplayName 'User Activity' -Tags ([PSCustomObject]@{ MigratedFromWorkbookId = 'src-3' }))
        )
    }

    BeforeEach {
        Mock Invoke-ScopeApiList -ModuleName WorkbookScope.Discovery { $script:DiscoveryWorkbooks }
    }

    It 'returns only tagged workbooks by default' {
        $found = @(Get-DestinationWorkbook -ArmEndpoint 'https://management.azure.com' -SubscriptionId 'sub' -ResourceGroupName 'rg' -WorkspaceResourceId '/workspace' -ThrottleDelayMs 0)
        $found.name | Should -Be @('one', 'three')
    }

    It 'returns all workbooks when explicitly widened' {
        $found = @(Get-DestinationWorkbook -ArmEndpoint 'https://management.azure.com' -SubscriptionId 'sub' -ResourceGroupName 'rg' -WorkspaceResourceId '/workspace' -IncludeAllWorkbooks -ThrottleDelayMs 0)
        $found.Count | Should -Be 3
    }

    It 'matches display names case-insensitively with wildcards' {
        $found = @(Get-DestinationWorkbook -ArmEndpoint 'https://management.azure.com' -SubscriptionId 'sub' -ResourceGroupName 'rg' -WorkspaceResourceId '/workspace' -IncludeAllWorkbooks -WorkbookFilter '*network*' -ThrottleDelayMs 0)
        $found.name | Should -Be 'two'
    }
}
