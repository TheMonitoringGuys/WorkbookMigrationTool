<#
.SYNOPSIS
    Opt-in probe that checks whether dual-scoped workbooks will actually render.
.DESCRIPTION
    Behind -ValidateQueries because it needs Log Analytics data-plane read access,
    which is a separate grant from the ARM permissions the re-scoping itself
    needs. A caller who can rewrite workbooks cannot necessarily query them.

    It answers the two questions a successful ARM write does not:

      1. Can this identity actually read both workspaces? A workbook updates
         cleanly and then renders empty when the viewer lacks Log Analytics
         Reader on the source. That is the single likeliest support call this
         tool generates, so it is worth proving rather than assuming.

      2. Do the tables a workbook reads exist in both workspaces? A table present
         in only one yields partial results rather than an error, which is far
         harder to notice than a failure.

    Nothing here writes. A failed validation never fails the run - the workbooks
    are already correctly scoped - it only adds findings to the report.
#>

Import-Module (Join-Path $PSScriptRoot 'WorkbookScope.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'WorkbookScope.Api.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'WorkbookScope.Engine.psm1') -Force -DisableNameChecking

function Invoke-WorkspaceQuery {
    <#
    .SYNOPSIS
        Runs a KQL query against a workspace via the Log Analytics data plane.
    .DESCRIPTION
        Uses the data-plane endpoint rather than ARM because the ARM query proxy
        does not accept the cross-workspace 'workspaces' parameter this module
        needs for its permission probe.
    .PARAMETER WorkspaceCustomerId
        The workspace GUID (properties.customerId), not the ARM resource ID.
    .PARAMETER AdditionalWorkspaceIds
        Extra workspaces to union in. Passing one turns this into the
        cross-workspace permission probe.
    .OUTPUTS
        PSCustomObject: Success, Rows, Error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogAnalyticsEndpoint,
        [Parameter(Mandatory)][string]$WorkspaceCustomerId,
        [Parameter(Mandatory)][string]$Query,
        [string[]]$AdditionalWorkspaceIds = @(),
        [int]$ThrottleDelayMs = 100
    )

    $uri = Get-LogAnalyticsQueryUri -LogAnalyticsEndpoint $LogAnalyticsEndpoint -WorkspaceId $WorkspaceCustomerId
    $body = @{ query = $Query }
    $extra = @(ConvertTo-SafeArray $AdditionalWorkspaceIds)
    if ($extra.Count -gt 0) { $body['workspaces'] = $extra }

    try {
        $response = Invoke-ScopeApi -Uri $uri -Method POST -Body $body `
            -ResourceUrl $LogAnalyticsEndpoint -ThrottleDelayMs $ThrottleDelayMs

        $rows = @()
        if ($response.tables -and @($response.tables).Count -gt 0) {
            $rows = @($response.tables[0].rows)
        }
        return [PSCustomObject]@{ Success = $true; Rows = $rows; Error = $null }
    }
    catch {
        return [PSCustomObject]@{
            Success = $false
            Rows    = @()
            Error   = (Format-ApiErrorDetail -ErrorRecord $_)
        }
    }
}

function Get-WorkspaceTableInventory {
    <#
    .SYNOPSIS
        Lists tables that have received data in a workspace within the lookback.
    .DESCRIPTION
        Reads the Usage table rather than enumerating schema, because a table can
        exist with no rows in it. What matters for a dashboard is whether data
        arrived, not whether the schema is defined.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogAnalyticsEndpoint,
        [Parameter(Mandatory)][string]$WorkspaceCustomerId,
        [int]$LookbackDays = 7,
        [int]$ThrottleDelayMs = 100
    )

    $query = "Usage | where TimeGenerated > ago($($LookbackDays)d) | summarize by DataType | project DataType"
    $result = Invoke-WorkspaceQuery -LogAnalyticsEndpoint $LogAnalyticsEndpoint `
        -WorkspaceCustomerId $WorkspaceCustomerId -Query $query -ThrottleDelayMs $ThrottleDelayMs

    if (-not $result.Success) {
        return [PSCustomObject]@{ Success = $false; Tables = @(); Error = $result.Error }
    }

    $tables = @($result.Rows | ForEach-Object { [string]$_[0] } | Where-Object { $_ })
    return [PSCustomObject]@{ Success = $true; Tables = $tables; Error = $null }
}

function Test-CrossWorkspaceAccess {
    <#
    .SYNOPSIS
        Proves the current identity can read both workspaces in one query.
    .DESCRIPTION
        This is the check that mirrors what a workbook actually does. A query
        that succeeds against each workspace separately can still fail when
        unioned, because the data plane evaluates permission on every workspace
        named in the request.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogAnalyticsEndpoint,
        [Parameter(Mandatory)][string]$DestinationCustomerId,
        [Parameter(Mandatory)][string]$SourceWorkspaceResourceId,
        [int]$ThrottleDelayMs = 100
    )

    # 'print' needs no tables and returns one row, so this measures permission
    # and nothing else - it cannot fail because a workspace happens to be empty.
    $result = Invoke-WorkspaceQuery -LogAnalyticsEndpoint $LogAnalyticsEndpoint `
        -WorkspaceCustomerId $DestinationCustomerId `
        -Query 'print probe = 1' `
        -AdditionalWorkspaceIds @($SourceWorkspaceResourceId) `
        -ThrottleDelayMs $ThrottleDelayMs

    if ($result.Success) {
        return [PSCustomObject]@{ Ok = $true; Error = $null }
    }

    $hint = $result.Error
    if ($hint -match '(?i)forbidden|unauthorized|does not have access|insufficient') {
        $hint = "$hint`n    This identity cannot read both workspaces in one query. Grant Log Analytics Reader on the source workspace to everyone who will view these workbooks."
    }
    return [PSCustomObject]@{ Ok = $false; Error = $hint }
}

function Test-ScopeParameterResolves {
    <#
    .SYNOPSIS
        Proves the hidden self-healing scope parameter can see the source workspace.
    .DESCRIPTION
        Self-healing scope depends on an Azure Resource Graph-backed resource
        picker. If Resource Graph returns no rows for the running identity, the
        workbook still renders but silently drops the source workspace from every
        query. This check turns that wrong-answer case into a validation finding.
    .OUTPUTS
        PSCustomObject: Resolves, Reason, Skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SourceWorkspaceId,
        [string]$SourceSubscriptionId,
        [int]$ThrottleDelayMs = 100
    )

    if ([string]::IsNullOrWhiteSpace($SourceSubscriptionId)) {
        return [PSCustomObject]@{
            Resolves = $false
            Reason   = 'Skipped because no source subscription id was supplied for the Resource Graph query.'
            Skipped  = $true
        }
    }

    try {
        $endpoint = ([string]$ArmEndpoint).TrimEnd('/')
        $uri = "$endpoint/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"
        $query = "resources`n| where type =~ 'microsoft.operationalinsights/workspaces'`n| where id =~ '$SourceWorkspaceId'`n| project value = id, label = id, selected = true"
        $body = @{
            subscriptions = @($SourceSubscriptionId)
            query         = $query
        }

        $response = Invoke-ScopeApi -Uri $uri -Method POST -Body $body `
            -ResourceUrl $endpoint -ThrottleDelayMs $ThrottleDelayMs

        $rows = @()
        if ($response -and $response.PSObject.Properties['data']) {
            $rows = @(ConvertTo-SafeArray $response.data)
        }

        if ($rows.Count -gt 0) {
            return [PSCustomObject]@{ Resolves = $true; Reason = $null; Skipped = $false }
        }

        return [PSCustomObject]@{
            Resolves = $false
            Reason   = 'Azure Resource Graph returned no matching source workspace. In self-healing mode that means the hidden source parameter resolves empty and viewers silently see destination-only data.'
            Skipped  = $false
        }
    }
    catch {
        $hint = Format-ApiErrorDetail -ErrorRecord $_
        if ($hint -match '(?i)forbidden|unauthorized|authorization|permission|does not have access|insufficient') {
            $hint = "$hint`n    Viewers without Resource Graph visibility of the source workspace will silently see destination-only data."
        }
        return [PSCustomObject]@{
            Resolves = $false
            Reason   = $hint
            Skipped  = $false
        }
    }
}

function Invoke-ScopeValidation {
    <#
    .SYNOPSIS
        Runs the full validation pass and returns findings for the report.
    .DESCRIPTION
        Never throws. Validation is diagnostic: the workbooks are already scoped
        by the time it runs, and a probe that cannot complete should degrade to a
        reported unknown rather than failing a successful run.
    .PARAMETER Workbooks
        The workbook objects that were processed, used to work out which tables
        each one depends on.
    .OUTPUTS
        The ValidationResult shape the report and HTML renderers expect.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogAnalyticsEndpoint,
        [Parameter(Mandatory)][string]$SourceCustomerId,
        [Parameter(Mandatory)][string]$DestinationCustomerId,
        [Parameter(Mandatory)][string]$SourceWorkspaceResourceId,
        [object[]]$Workbooks = @(),
        [int]$LookbackDays = 7,
        [int]$ThrottleDelayMs = 100,
        [string]$ScopeMode = 'SelfHealing',
        [string]$SourceSubscriptionId,
        [string]$ArmEndpoint
    )

    Write-Host "  Validating query scope against both workspaces..." -ForegroundColor Cyan

    $validation = [PSCustomObject]@{
        SourceTables      = @()
        DestinationTables = @()
        OnlyInSource      = @()
        OnlyInDestination = @()
        CrossQueryOk      = $false
        CrossQueryError   = $null
        ScopeParameterResolves = $null
        ScopeParameterError    = $null
        WorkbookFindings  = @()
    }

    if ($ScopeMode -eq 'SelfHealing' -and -not [string]::IsNullOrWhiteSpace($ArmEndpoint)) {
        $scopeParameter = Test-ScopeParameterResolves -ArmEndpoint $ArmEndpoint `
            -SourceWorkspaceId $SourceWorkspaceResourceId `
            -SourceSubscriptionId $SourceSubscriptionId `
            -ThrottleDelayMs $ThrottleDelayMs

        if ($scopeParameter.Skipped) {
            Write-Host "    Scope parameter query: SKIPPED" -ForegroundColor Yellow
            Write-Host "      $($scopeParameter.Reason)" -ForegroundColor Yellow
        }
        elseif ($scopeParameter.Resolves) {
            Write-Host "    Scope parameter query: OK" -ForegroundColor Green
        }
        else {
            Write-Host "    Scope parameter query: FAILED" -ForegroundColor Red
            Write-Host "      $($scopeParameter.Reason)" -ForegroundColor Red
        }

        $validation.ScopeParameterResolves = [bool]$scopeParameter.Resolves
        $validation.ScopeParameterError = $scopeParameter.Reason
    }

    $cross = Test-CrossWorkspaceAccess -LogAnalyticsEndpoint $LogAnalyticsEndpoint `
        -DestinationCustomerId $DestinationCustomerId `
        -SourceWorkspaceResourceId $SourceWorkspaceResourceId `
        -ThrottleDelayMs $ThrottleDelayMs

    $validation.CrossQueryOk = $cross.Ok
    $validation.CrossQueryError = $cross.Error

    if ($cross.Ok) {
        Write-Host "    Cross-workspace query: OK" -ForegroundColor Green
    }
    else {
        Write-Host "    Cross-workspace query: FAILED" -ForegroundColor Red
        Write-Host "      $($cross.Error)" -ForegroundColor Red
    }

    $srcInv = Get-WorkspaceTableInventory -LogAnalyticsEndpoint $LogAnalyticsEndpoint `
        -WorkspaceCustomerId $SourceCustomerId -LookbackDays $LookbackDays -ThrottleDelayMs $ThrottleDelayMs
    $dstInv = Get-WorkspaceTableInventory -LogAnalyticsEndpoint $LogAnalyticsEndpoint `
        -WorkspaceCustomerId $DestinationCustomerId -LookbackDays $LookbackDays -ThrottleDelayMs $ThrottleDelayMs

    if (-not $srcInv.Success) {
        Write-Warning "Could not inventory source workspace tables: $($srcInv.Error)"
    }
    if (-not $dstInv.Success) {
        Write-Warning "Could not inventory destination workspace tables: $($dstInv.Error)"
    }

    $validation.SourceTables = @($srcInv.Tables)
    $validation.DestinationTables = @($dstInv.Tables)

    # Only meaningful when both inventories came back; comparing against an empty
    # list because a probe failed would report every table as missing.
    if ($srcInv.Success -and $dstInv.Success) {
        $srcSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($srcInv.Tables), [System.StringComparer]::OrdinalIgnoreCase)
        $dstSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($dstInv.Tables), [System.StringComparer]::OrdinalIgnoreCase)

        $validation.OnlyInSource = @($srcInv.Tables | Where-Object { -not $dstSet.Contains($_) })
        $validation.OnlyInDestination = @($dstInv.Tables | Where-Object { -not $srcSet.Contains($_) })

        $findings = [System.Collections.Generic.List[object]]::new()
        foreach ($wb in @(ConvertTo-SafeArray $Workbooks)) {
            $name = [string]$wb.DisplayName
            $needed = @(ConvertTo-SafeArray $wb.Tables)
            if ($needed.Count -eq 0) { continue }

            $missingDst = @($needed | Where-Object { -not $dstSet.Contains($_) })
            $missingSrc = @($needed | Where-Object { -not $srcSet.Contains($_) })

            # Report only asymmetry - a name present in one workspace and absent
            # from the other. That is the whole signal this tool exists to
            # surface, and restricting to it also removes the table extractor's
            # false positives at a stroke: a misread column name is absent from
            # both workspaces, so it can never be asymmetric. A name genuinely
            # missing from both is a pre-existing gap in the workbook, not
            # something dual scoping caused or can fix.
            $onlyMissingDst = @($missingDst | Where-Object { $srcSet.Contains($_) })
            $onlyMissingSrc = @($missingSrc | Where-Object { $dstSet.Contains($_) })
            if ($onlyMissingDst.Count -eq 0 -and $onlyMissingSrc.Count -eq 0) { continue }

            $findings.Add([PSCustomObject]@{
                    DisplayName          = $name
                    MissingInDestination = $onlyMissingDst
                    MissingInSource      = $onlyMissingSrc
                })
        }
        $validation.WorkbookFindings = @($findings.ToArray())
    }

    return $validation
}

Export-ModuleMember -Function @(
    'Invoke-WorkspaceQuery'
    'Get-WorkspaceTableInventory'
    'Test-CrossWorkspaceAccess'
    'Test-ScopeParameterResolves'
    'Invoke-ScopeValidation'
)
