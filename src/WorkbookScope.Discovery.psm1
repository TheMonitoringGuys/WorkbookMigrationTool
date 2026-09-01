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

        The listing is done in one request that carries every workbook's content,
        because that is by far the cheapest way to do it. When that request fails
        the function falls back to listing metadata only and fetching each
        workbook's content separately - many small requests instead of one large
        one. See the comment at the fallback for why.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkspaceResourceId,
        [switch]$IncludeAllWorkbooks,
        [string]$WorkbookFilter,
        [int]$ThrottleDelayMs = 100,
        # Receives the IDs of workbooks that exist but could not be read, so the
        # caller can record them as failures. Without this they would be dropped
        # here, and a run that silently processed eleven of sixteen workbooks
        # would report success and exit 0 - the precise failure this tool exists
        # to remove, arriving through a different door.
        [ref]$UnreadableWorkbookIds
    )

    $uri = Get-WorkbooksUri -ArmEndpoint $ArmEndpoint -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName -SourceId $WorkspaceResourceId

    Write-Host "  Fetching workbooks from destination..." -ForegroundColor Cyan

    $workbooks = $null
    $unreadable = [System.Collections.Generic.List[string]]::new()
    # How many workbooks are actually bound to this workspace. Kept separate from
    # the count that survives fetching, because reporting "from 11 bound" when
    # sixteen exist would hide the very gap the operator needs to notice.
    $boundTotal = 0

    try {
        $workbooks = @(Invoke-ScopeApiList -Uri $uri -ThrottleDelayMs $ThrottleDelayMs)
        $boundTotal = $workbooks.Count
    }
    catch {
        # A single request asking for every workbook's content can return several
        # megabytes. This tool reads the destination, which holds every migrated
        # workbook, so its response is much larger than the equivalent call in the
        # Sentinel Migration Assistant even though the request is identical. An
        # intermediary that refuses a body that size reports it as a gateway
        # error, and the accompanying text is frequently misleading.
        #
        # Rather than fail, ask for the same data in pieces small enough that no
        # single response is large. Slower, but it completes.
        $bulkError = $_.Exception.Message
        Write-Warning "Listing workbooks with content failed: $bulkError"
        Write-Host "  Retrying without bulk content, one workbook at a time..." -ForegroundColor Yellow

        $listUri = Get-WorkbooksUri -ArmEndpoint $ArmEndpoint -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName -SourceId $WorkspaceResourceId -ExcludeContent

        # Whether this lighter request succeeds is the single most useful fact
        # available when something goes wrong here, so its failure must not escape
        # unexplained. The two outcomes mean different things:
        #
        #   bulk fails, this succeeds -> the payload was the problem, and
        #                                fetching per workbook is the answer
        #   both fail                 -> not size. The same fault affects a 13 KB
        #                                request, so look at auth or the network.
        #
        # Reporting both errors together is what lets someone tell those apart
        # without another round trip to the customer.
        $stubs = $null
        try {
            $stubs = @(Invoke-ScopeApiList -Uri $listUri -ThrottleDelayMs $ThrottleDelayMs)
        }
        catch {
            throw @"
Could not list workbooks in the destination, with or without content.

  Listing with content:    $bulkError
  Listing without content: $($_.Exception.Message)

The second request returns roughly 14 KB, so response size is not the cause. Both
requests share one code path, one token and one network route, which points at
authentication or something between this machine and Azure rather than at the
workbooks themselves.

Run tools/Test-ScopeConnection.ps1 to identify which.
"@
        }

        $boundTotal = $stubs.Count
        Write-Host "  Listed $($stubs.Count) workbook(s); fetching content individually..." -ForegroundColor Yellow

        $hydrated = [System.Collections.Generic.List[object]]::new()
        foreach ($stub in $stubs) {
            if (-not $stub.id) { continue }
            # The list returns full ARM resource IDs; the item URI builder wants
            # just the workbook's name segment.
            $wbId = ($stub.id -split '/')[-1]
            try {
                $itemUri = Get-WorkbookUri -ArmEndpoint $ArmEndpoint -SubscriptionId $SubscriptionId `
                    -ResourceGroupName $ResourceGroupName -WorkbookId $wbId -IncludeContent
                $full = Invoke-ScopeApi -Uri $itemUri -Method GET -ThrottleDelayMs $ThrottleDelayMs
                if ($full) { $hydrated.Add($full) }
            }
            catch {
                # One unreadable workbook must not cost the other fifteen, but it
                # must not vanish either. It goes back to the caller so the run
                # records a failure rather than quietly shrinking its own scope.
                $unreadable.Add([string]$wbId)
                Write-Warning "  Could not read workbook '$wbId': $($_.Exception.Message)"
            }
        }

        # Only a genuine wall of failures justifies giving up. A destination that
        # legitimately holds no workbooks reaches here with nothing attempted, and
        # claiming "every individual fetch failed too" would be false and would
        # send someone hunting a permissions problem that does not exist.
        if ($hydrated.Count -eq 0 -and $unreadable.Count -gt 0) {
            throw "Could not read any workbook content from the destination. The bulk listing failed, and all $($unreadable.Count) individual fetch(es) failed too. Original error: $bulkError"
        }

        if ($unreadable.Count -gt 0) {
            Write-Warning "  $($unreadable.Count) workbook(s) could not be read. They are reported as failures, not skipped silently."
        }

        $workbooks = @($hydrated)
    }

    if ($UnreadableWorkbookIds) { $UnreadableWorkbookIds.Value = @($unreadable) }

    $total = $boundTotal

    $excludedByTag = @()
    if ($IncludeAllWorkbooks) {
        $filtered = @($workbooks)
    }
    else {
        $filtered = @($workbooks | Where-Object { Test-WorkbookIsMigrated -Workbook $_ })
        $excludedByTag = @($workbooks | Where-Object { -not (Test-WorkbookIsMigrated -Workbook $_) })
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

    # Say plainly which workbooks are being left out, and why.
    #
    # The count above technically carries this - "3 migrated (from 16 bound)" - but
    # it is easy to read past, and the consequence only shows up later as some
    # workbooks displaying the old workspace's data and others not. Anything not
    # created by the migration assistant is skipped here: workbooks built by hand,
    # and anything installed from a Content Hub solution. Naming them costs a few
    # lines and removes an entire class of confusion.
    if ($excludedByTag.Count -gt 0) {
        Write-Host ''
        Write-Warning "$($excludedByTag.Count) workbook(s) bound to this workspace are NOT being updated, because they carry no MigratedFromWorkbookId tag and so were not created by the Sentinel Migration Assistant:"

        $show = @($excludedByTag | Select-Object -First 10)
        foreach ($w in $show) {
            Write-Host "      - $(Get-WorkbookDisplayName -Workbook $w)" -ForegroundColor Yellow
        }
        if ($excludedByTag.Count -gt $show.Count) {
            Write-Host "      ... and $($excludedByTag.Count - $show.Count) more" -ForegroundColor Yellow
        }

        Write-Host ''
        Write-Host '    These will keep showing destination data only. To include them, re-run with:' -ForegroundColor Yellow
        Write-Host '       -IncludeAllWorkbooks' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '    Be aware that updating a Content Hub solution can revert its own workbooks,' -ForegroundColor Yellow
        Write-Host '    so those may need scoping again afterwards.' -ForegroundColor Yellow
        Write-Host ''
    }

    return @($filtered)
}

Export-ModuleMember -Function @(
    'Get-DestinationWorkbook'
    'Test-WorkbookIsMigrated'
    'Get-WorkbookDisplayName'
    'Get-WorkbookScopeTag'
)
