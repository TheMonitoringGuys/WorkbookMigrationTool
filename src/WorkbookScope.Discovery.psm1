Import-Module (Join-Path $PSScriptRoot 'WorkbookScope.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'WorkbookScope.Api.psm1') -Force -DisableNameChecking

function ConvertTo-ScopeTagHashtable {
    <#
    .SYNOPSIS
        Copies ARM tags into a mutable hashtable.
    .DESCRIPTION
        ARM responses surface tags as either a hashtable or a PSCustomObject
        depending on the caller and serializer. Normalising once keeps tag tests
        and updates from depending on that representation.
    #>
    [CmdletBinding()]
    param([object]$Tags)

    $copy = @{}
    if ($null -eq $Tags) { return $copy }

    if ($Tags -is [System.Collections.IDictionary]) {
        foreach ($key in $Tags.Keys) {
            if ($null -ne $key) { $copy[[string]$key] = $Tags[$key] }
        }
        return $copy
    }

    foreach ($prop in @($Tags.PSObject.Properties)) {
        if ($prop.Name) { $copy[$prop.Name] = $prop.Value }
    }
    return $copy
}

function Get-ScopeTagValue {
    <#
    .SYNOPSIS
        Reads one tag value by name from any ARM tag representation.
    #>
    [CmdletBinding()]
    param(
        [object]$Tags,
        [Parameter(Mandatory)][string]$Name
    )

    $tagTable = ConvertTo-ScopeTagHashtable -Tags $Tags
    foreach ($key in @($tagTable.Keys)) {
        if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $tagTable[$key]
        }
    }
    return $null
}

function Test-WorkbookIsMigrated {
    <#
    .SYNOPSIS
        Returns true when a workbook carries the migration tracking tag.
    .DESCRIPTION
        The Sentinel Migration Assistant tags every workbook it creates with
        MigratedFromWorkbookId. That tag is the safest default scope for this
        tool because it excludes workbooks installed by Content Hub or created
        manually in the same resource group.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Workbook)

    $value = Get-ScopeTagValue -Tags $Workbook.tags -Name 'MigratedFromWorkbookId'
    return -not [string]::IsNullOrWhiteSpace([string]$value)
}

function Get-WorkbookDisplayName {
    <#
    .SYNOPSIS
        Returns the best operator-facing name for a workbook.
    .DESCRIPTION
        Workbook displayName is the primary label. The migration tool also writes
        hidden-title because Azure Workbooks use it in parts of the gallery UI.
        The resource name is the final fallback.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Workbook)

    $displayName = [string]$Workbook.properties.displayName
    if (-not [string]::IsNullOrWhiteSpace($displayName)) { return $displayName }

    $hiddenTitle = [string](Get-ScopeTagValue -Tags $Workbook.tags -Name 'hidden-title')
    if (-not [string]::IsNullOrWhiteSpace($hiddenTitle)) { return $hiddenTitle }

    $name = [string]$Workbook.name
    if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }

    return '(unnamed workbook)'
}

function Get-WorkbookScopeTag {
    <#
    .SYNOPSIS
        Builds the tag set to write after applying or reverting dual scope.
    .DESCRIPTION
        Existing tags are copied before this tool's tags are changed. Azure tag
        values are limited to 256 characters, so the source tag stores the
        workspace name rather than the full workspace resource ID.
    #>
    [CmdletBinding()]
    param(
        [object]$ExistingTags,
        [string]$SourceWorkspaceName,
        [switch]$Revert
    )

    $tags = ConvertTo-ScopeTagHashtable -Tags $ExistingTags

    if ($Revert) {
        foreach ($tagName in @('DualScopeApplied', 'DualScopeSourceWorkspace')) {
            foreach ($key in @($tags.Keys)) {
                if ([string]::Equals([string]$key, $tagName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $tags.Remove($key)
                }
            }
        }
    }
    else {
        $tags['DualScopeApplied'] = (Get-Date).ToUniversalTime().ToString('o')
        $tags['DualScopeSourceWorkspace'] = $SourceWorkspaceName
    }

    return $tags
}

function Get-DestinationWorkbook {
    <#
    .SYNOPSIS
        Lists destination workbooks that this tool should update.
    .DESCRIPTION
        By default this returns only workbooks tagged with MigratedFromWorkbookId,
        which are the workbooks created by the Sentinel Migration Assistant.

        -IncludeAllWorkbooks widens the blast radius to every Sentinel workbook
        bound to the destination workspace. That includes workbooks the migration
        never created, such as workbooks installed from a Content Hub solution;
        a later solution update can revert those workbooks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkspaceResourceId,
        [switch]$IncludeAllWorkbooks,
        [string]$WorkbookFilter,
        [int]$ThrottleDelayMs = 100
    )

    $uri = Get-WorkbooksUri -ArmEndpoint $ArmEndpoint -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName -SourceId $WorkspaceResourceId

    Write-Host "  Fetching workbooks from destination..." -ForegroundColor Cyan
    $workbooks = @(Invoke-ScopeApiList -Uri $uri -ThrottleDelayMs $ThrottleDelayMs)
    $total = $workbooks.Count

    if ($IncludeAllWorkbooks) {
        $filtered = @($workbooks)
    }
    else {
        $filtered = @($workbooks | Where-Object { Test-WorkbookIsMigrated -Workbook $_ })
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkbookFilter)) {
        $filtered = @($filtered | Where-Object { (Get-WorkbookDisplayName -Workbook $_) -like $WorkbookFilter })
    }

    if ($IncludeAllWorkbooks) {
        Write-Host "  Found $($filtered.Count) workbook(s) (from $total bound to the destination workspace)" -ForegroundColor Cyan
    }
    else {
        Write-Host "  Found $($filtered.Count) migrated workbook(s) (from $total bound to the destination workspace)" -ForegroundColor Cyan
    }

    return @($filtered)
}

Export-ModuleMember -Function @(
    'Get-DestinationWorkbook'
    'Test-WorkbookIsMigrated'
    'Get-WorkbookDisplayName'
    'Get-WorkbookScopeTag'
)
