Import-Module (Join-Path $PSScriptRoot 'WorkbookScope.Common.psm1') -Force -DisableNameChecking

function Get-ScopeProp {
    param([object]$Object, [Parameter(Mandatory)][string]$Path, [object]$Default = $null)
    $cur = $Object
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $cur) { return $Default }
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($seg)) { return $Default }
            $cur = $cur[$seg]
            continue
        }
        $member = $cur.PSObject.Properties[$seg]
        if ($null -eq $member) { return $Default }
        $cur = $member.Value
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function ConvertTo-ScopeHtmlEncoded {
    param([object]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function ConvertTo-ScopeSlug {
    param([string]$Text)
    $s = ([string]$Text).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    return "sec-$($s.Trim('-'))"
}

function New-ScopeKpiCard {
    param(
        [string]$Label,
        [object]$Value,
        [string]$Anchor = '',
        [ValidateSet('default', 'good', 'warn', 'bad')]
        [string]$Tone = 'default'
    )
    $toneCls = if ($Tone -ne 'default') { " tone-$Tone" } else { '' }
    $inner = @"
  <div class="kpi-value">$(ConvertTo-ScopeHtmlEncoded $Value)</div>
  <div class="kpi-label">$(ConvertTo-ScopeHtmlEncoded $Label)</div>
"@
    if ($Anchor) { return "<a class=""kpi kpi-link$toneCls"" href=""#$Anchor"">$inner</a>" }
    return "<div class=""kpi$toneCls"">$inner</div>"
}

function ConvertTo-ScopeNumber {
    param([object]$Value)
    if ($null -eq $Value) { return 0.0 }
    $result = 0.0
    if ([double]::TryParse([string]$Value, [ref]$result)) { return $result }
    return 0.0
}

function New-ScopeBarChart {
    param([string]$Title, [object[]]$Pairs, [string]$Color = '#7c3aed')
    $pairs = @(ConvertTo-ItemList $Pairs)
    if ($pairs.Count -eq 0) {
        return "<div class='chart'><h3>$(ConvertTo-ScopeHtmlEncoded $Title)</h3><p class='muted'>No data available.</p></div>"
    }
    $max = 0.0
    foreach ($p in $pairs) {
        $n = ConvertTo-ScopeNumber $p.Value
        if ($n -gt $max) { $max = $n }
    }
    if ($max -le 0) { $max = 1 }
    $rows = foreach ($p in $pairs) {
        $pct = [math]::Round(((ConvertTo-ScopeNumber $p.Value) / $max) * 100, 1)
        @"
<div class="bar-row">
  <div class="bar-label" title="$(ConvertTo-ScopeHtmlEncoded $p.Label)">$(ConvertTo-ScopeHtmlEncoded $p.Label)</div>
  <div class="bar-track"><div class="bar-fill" style="width:$pct%;background:$Color"></div></div>
  <div class="bar-value">$(ConvertTo-ScopeHtmlEncoded $p.Value)</div>
</div>
"@
    }
    return "<div class='chart'><h3>$(ConvertTo-ScopeHtmlEncoded $Title)</h3>$($rows -join "`n")</div>"
}

function Get-ScopeKpis {
    param([object]$RunResult)
    $results = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Results'))
    $errors = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Errors'))
    $countBy = {
        param($Pattern)
        @($results | Where-Object { (Get-NormalizedAction $_.Action) -match $Pattern }).Count
    }
    [ordered]@{
        'Scope mode'          = Get-ScopeModeLabel -RunResult $RunResult
        'Workbooks processed' = $results.Count
        'Scoped to both'      = & $countBy '^Scoped$'
        'Reverted'            = & $countBy '^Reverted$'
        'Already scoped'      = & $countBy '^AlreadyScoped$'
        'Not scoped'          = & $countBy '^NotScoped$'
        'Skipped'             = & $countBy '^Skipped$'
        'Failed'              = & $countBy '^Failed$'
        'Eligible queries'    = ($results | Measure-Object -Property Eligible -Sum).Sum
        'Ineligible queries'  = ($results | Measure-Object -Property Ineligible -Sum).Sum
        'Parameters patched'  = ($results | Measure-Object -Property ParametersPatched -Sum).Sum
        'Errors'              = $errors.Count
    }
}

function Get-ScopeModeLabel {
    param([object]$RunResult)
    $scopeMode = [string](Get-ScopeProp $RunResult 'ScopeMode')
    if ([string]::IsNullOrWhiteSpace($scopeMode)) { return 'Literal' }
    return $scopeMode
}

function Format-ScopeCommandArgument {
    param([object]$Value)
    $escaped = ([string]$Value) -replace "'", "''"
    return "'$escaped'"
}

function Get-ScopeRevertCommand {
    param([object]$RunResult)
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('.\Sentinel-Workbook-Scope-Assistant.ps1') | Out-Null
    $parts.Add('-SourceSubscriptionId') | Out-Null
    $parts.Add((Format-ScopeCommandArgument (Get-ScopeProp $RunResult 'Source.SubscriptionId'))) | Out-Null
    $parts.Add('-SourceResourceGroup') | Out-Null
    $parts.Add((Format-ScopeCommandArgument (Get-ScopeProp $RunResult 'Source.ResourceGroupName'))) | Out-Null
    $parts.Add('-SourceWorkspace') | Out-Null
    $parts.Add((Format-ScopeCommandArgument (Get-ScopeProp $RunResult 'Source.WorkspaceName'))) | Out-Null
    $parts.Add('-DestinationSubscriptionId') | Out-Null
    $parts.Add((Format-ScopeCommandArgument (Get-ScopeProp $RunResult 'Destination.SubscriptionId'))) | Out-Null
    $parts.Add('-DestinationResourceGroup') | Out-Null
    $parts.Add((Format-ScopeCommandArgument (Get-ScopeProp $RunResult 'Destination.ResourceGroupName'))) | Out-Null
    $parts.Add('-DestinationWorkspace') | Out-Null
    $parts.Add((Format-ScopeCommandArgument (Get-ScopeProp $RunResult 'Destination.WorkspaceName'))) | Out-Null
    $parts.Add('-Revert') | Out-Null
    $parts.Add('-Execute') | Out-Null
    $parts.Add('-Force') | Out-Null
    return ($parts.ToArray() -join ' ')
}

function Get-ScopeFailedWorkbookNames {
    param([object]$RunResult)
    $results = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Results'))
    return @($results |
        Where-Object { (Get-NormalizedAction $_.Action) -eq 'Failed' } |
        ForEach-Object {
            if ($_.DisplayName) { [string]$_.DisplayName }
            elseif ($_.WorkbookId) { [string]$_.WorkbookId }
            else { 'unknown workbook' }
        })
}

function Get-ScopeDecommissionReadiness {
    param([object]$RunResult)
    $results = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Results'))
    $scopeMode = Get-ScopeModeLabel -RunResult $RunResult
    $operation = [string](Get-ScopeProp $RunResult 'Operation')
    $failedNames = @(Get-ScopeFailedWorkbookNames -RunResult $RunResult)
    $scoped = @($results | Where-Object { (Get-NormalizedAction $_.Action) -in @('Scoped', 'AlreadyScoped') })
    $reverted = @($results | Where-Object { (Get-NormalizedAction $_.Action) -eq 'Reverted' })

    if ($failedNames.Count -gt 0) {
        return [PSCustomObject]@{
            Tone    = 'bad'
            Message = "Decommission readiness is unknown for failed workbook(s): $($failedNames -join ', '). Fix those failures before turning off the source workspace."
        }
    }

    if ($operation -eq 'Revert' -or $reverted.Count -gt 0) {
        return [PSCustomObject]@{
            Tone    = 'good'
            Message = 'The workbooks are back to destination-only scope and the source workspace can be removed.'
        }
    }

    if ($scoped.Count -gt 0 -and $scopeMode -eq 'SelfHealing') {
        return [PSCustomObject]@{
            Tone    = 'good'
            Message = 'The scoped workbooks will keep working when the source workspace is deleted; no revert is required first.'
        }
    }

    if ($scoped.Count -gt 0) {
        return [PSCustomObject]@{
            Tone    = 'warn'
            Message = "The scoped workbooks will stop rendering when the source workspace is deleted and must be reverted first. Revert command: $(Get-ScopeRevertCommand -RunResult $RunResult)"
        }
    }

    return [PSCustomObject]@{
        Tone    = 'warn'
        Message = 'No scoped workbook results were recorded, so decommission readiness cannot be determined from this run.'
    }
}

function Get-ScopeActionBreakdown {
    param([object[]]$Results)
    $rows = @(ConvertTo-ItemList $Results)
    if ($rows.Count -eq 0) { return @() }
    return $rows |
        Group-Object -Property { Get-NormalizedAction $_.Action } |
        Sort-Object Count -Descending |
        ForEach-Object { [PSCustomObject]@{ Label = $_.Name; Value = $_.Count } }
}

function Get-ScopeNextSteps {
    param([object]$RunResult)
    $results = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Results'))
    $validation = Get-ScopeProp $RunResult 'Validation'
    $errors = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Errors'))
    $warnings = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Preflight.Warnings'))
    $pfErrors = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Preflight.Errors'))
    $sourceName = [string](Get-ScopeProp $RunResult 'Source.WorkspaceName' 'source workspace')
    $destName = [string](Get-ScopeProp $RunResult 'Destination.WorkspaceName' 'destination workspace')
    $mode = [string](Get-ScopeProp $RunResult 'Mode')
    $operation = [string](Get-ScopeProp $RunResult 'Operation')
    $scopeMode = Get-ScopeModeLabel -RunResult $RunResult
    $steps = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($Tone, $Title, $Detail, $Count)
        $steps.Add([PSCustomObject]@{ Order = $steps.Count + 1; Tone = $Tone; Title = $Title; Detail = $Detail; Count = $Count }) | Out-Null
    }
    if ($mode -eq 'DryRun') {
        & $add 'warn' 'Run the change for real' 'Exact command: re-run the same command that produced this report and add -Execute, or replace -DryRun with -Execute. Dry run is the default, so no workbook was changed in this run.' 0
    }
    $scoped = @($results | Where-Object { (Get-NormalizedAction $_.Action) -eq 'Scoped' })
    if ($scoped.Count -gt 0) {
        & $add 'info' 'Confirm viewer permissions on both workspaces' "Workbook viewers now need Log Analytics Reader on both $sourceName and $destName. The tool sets crossComponentResources; no KQL is rewritten." $scoped.Count
        if ($scopeMode -eq 'Literal') {
            & $add 'warn' 'Revert literal scope before decommissioning' "Literal scoped workbooks will stop rendering when the source workspace is deleted. Before removing it, run: $(Get-ScopeRevertCommand -RunResult $RunResult)." $scoped.Count
        }
        else {
            & $add 'info' 'Treat revert as optional tidy-up' 'Self-healing scoped workbooks keep rendering after the source workspace is deleted. A later revert is optional tidy-up if you want to remove the hidden source parameter and scope manifest.' $scoped.Count
        }
    }
    $reverted = @($results | Where-Object { (Get-NormalizedAction $_.Action) -eq 'Reverted' })
    if ($reverted.Count -gt 0) {
        & $add 'good' 'Verify destination-only workbook scope' "These workbooks were reverted to $destName only. Open representative workbooks before removing source workspace access." $reverted.Count
    }
    if ([bool](Get-ScopeProp $RunResult 'Preflight.CrossSubscription')) {
        & $add 'warn' 'Check cross-subscription workbook pickers' 'The source and destination workspaces are in different subscriptions. Any workbook picker or Azure portal view used with these workbooks must allow both subscriptions.' 0
    }
    if ([bool](Get-ScopeProp $RunResult 'Preflight.CrossRegion')) {
        & $add 'warn' 'Review cross-region query expectations' 'The source and destination workspaces are in different regions. Validate latency and table coverage with real workbook users.' 0
    }
    $onlySource = @()
    $onlyDest = @()
    if ($validation) {
        $onlySource = @(ConvertTo-ItemList $validation.OnlyInSource)
        $onlyDest = @(ConvertTo-ItemList $validation.OnlyInDestination)
    }
    if ($onlySource.Count -gt 0) {
        & $add 'warn' 'Connect missing destination data sources' ("These tables exist only in the source workspace: " + ($onlySource -join ', ') + ". Destination-only operation needs them populated before source decommissioning.") $onlySource.Count
    }
    if ($onlyDest.Count -gt 0) {
        & $add 'info' 'Review tables found only in the destination' ("These tables exist only in the destination workspace: " + ($onlyDest -join ', ') + ". Confirm this is expected after migration.") $onlyDest.Count
    }
    if ($validation -and $validation.CrossQueryOk -eq $false) {
        & $add 'bad' 'Fix cross-workspace query validation' "The validation query failed: $($validation.CrossQueryError). Resolve this before relying on combined workbook views." 1
    }
    if ($validation -and $validation.PSObject.Properties['ScopeParameterResolves'] -and $validation.ScopeParameterResolves -eq $false) {
        & $add 'bad' 'Fix self-healing scope parameter validation' "The hidden source parameter did not resolve: $($validation.ScopeParameterError). In self-healing mode this silently hides source data, so resolve it before relying on combined workbook views." 1
    }
    $failed = @($results | Where-Object { (Get-NormalizedAction $_.Action) -eq 'Failed' })
    if ($failed.Count -gt 0) {
        $names = @($failed | ForEach-Object { if ($_.DisplayName) { $_.DisplayName } else { $_.WorkbookId } }) -join ', '
        & $add 'bad' 'Re-run failed workbooks after fixing the error' "The failed workbook(s) were: $names. Fix the listed reason and re-run the $operation operation." $failed.Count
    }
    if ($pfErrors.Count -gt 0) {
        & $add 'bad' 'Resolve preflight errors' 'Preflight errors mean the run could not prove the workspace inputs are ready. Resolve the listed errors before applying workbook scope changes.' $pfErrors.Count
    }
    elseif ($warnings.Count -gt 0) {
        & $add 'warn' 'Review preflight warnings' 'The run continued with warnings. Review them before treating the scoped workbooks as production-ready.' $warnings.Count
    }
    if ($errors.Count -gt 0) {
        & $add 'bad' 'Work through collected errors' 'Each collected error names the component, message, and remediation when available. These are the best starting points for a targeted re-run.' $errors.Count
    }
    if ($steps.Count -eq 0) {
        & $add 'good' 'No follow-up actions identified' 'This run did not produce failures, validation gaps, warnings, or permission follow-up beyond normal operational review.' 0
    }
    return $steps.ToArray()
}

function New-ScopeNextStepsHtml {
    param([object[]]$Steps)
    $items = foreach ($s in @(ConvertTo-ItemList $Steps)) {
        $badge = if ($s.Count -and [int]$s.Count -gt 0) { "<span class=""count"">$([int]$s.Count)</span>" } else { '' }
        @"
    <li class="step tone-$($s.Tone)">
      <div class="step-title">$(ConvertTo-ScopeHtmlEncoded $s.Title) $badge</div>
      <div class="step-detail">$(ConvertTo-ScopeHtmlEncoded (([string]$s.Detail) -replace '\s*\r?\n\s*', ' ').Trim())</div>
    </li>
"@
    }
    return @"
  <h2 id="sec-next-steps">Next Steps</h2>
  <p class="muted">Derived from this run. Items are ordered by how much they block a reliable workbook transition.</p>
  <ol class="steps">
$($items -join "`n")
  </ol>
"@
}

function New-ScopeDetailTable {
    param([Parameter(Mandatory)][string]$Title, [object[]]$Rows)
    $rows = @(ConvertTo-ItemList $Rows)
    $id = ConvertTo-ScopeSlug $Title
    $tid = "$id-tbl"
    if ($rows.Count -eq 0) {
        return @"
<details id="$id" class="detail">
  <summary>$(ConvertTo-ScopeHtmlEncoded $Title) <span class="count">0</span></summary>
  <p class="muted">No items collected.</p>
</details>
"@
    }
    $columns = @($rows[0].PSObject.Properties.Name)
    $headCells = for ($i = 0; $i -lt $columns.Count; $i++) {
        "<th onclick=""sortTable('$tid',$i,this)"">$(ConvertTo-ScopeHtmlEncoded $columns[$i])<span class=""sort-ind""></span></th>"
    }
    $bodyRows = foreach ($r in $rows) {
        $normalized = Get-NormalizedAction $r.Action
        $cls = switch ($normalized) {
            'Failed' { ' class="row-bad"' }
            'Skipped' { ' class="row-warn"' }
            default { '' }
        }
        $cells = foreach ($c in $columns) { "<td>$(ConvertTo-ScopeHtmlEncoded $r.$c)</td>" }
        "<tr$cls>$($cells -join '')</tr>"
    }
    return @"
<details id="$id" class="detail">
  <summary>$(ConvertTo-ScopeHtmlEncoded $Title) <span class="count">$($rows.Count)</span></summary>
  <input class="tbl-search" type="search" placeholder="Filter $(ConvertTo-ScopeHtmlEncoded $Title)…" oninput="filterTable('$tid',this.value)">
  <div class="tbl-wrap">
  <table id="$tid" class="detail-table">
    <thead><tr>$($headCells -join '')</tr></thead>
    <tbody>
$($bodyRows -join "`n")
    </tbody>
  </table>
  </div>
</details>
"@
}

function ConvertTo-WorkbookRows {
    param([object]$RunResult)
    foreach ($r in @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Results'))) {
        [PSCustomObject][ordered]@{
            Action            = Format-ActionLabel $r.Action
            DisplayName       = $r.DisplayName
            WorkbookId        = $r.WorkbookId
            Method            = $r.Method
            Eligible          = $r.Eligible
            Ineligible        = $r.Ineligible
            Added             = $r.Added
            Replaced          = $r.Replaced
            ParametersPatched = $r.ParametersPatched
            FallbackUpdated   = $r.FallbackUpdated
            ParameterNames    = (@(ConvertTo-ItemList $r.ParameterNames) -join '; ')
            SnapshotPath      = $r.SnapshotPath
            Reason            = $r.Reason
        }
    }
}

function ConvertTo-ErrorRows {
    param([object]$RunResult)
    foreach ($e in @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Errors'))) {
        [PSCustomObject][ordered]@{
            Component   = $e.Component
            Message     = $e.Message
            Remediation = $e.Remediation
            Critical    = $e.Critical
        }
    }
}

function ConvertTo-ValidationRows {
    param([object]$RunResult)
    $validation = Get-ScopeProp $RunResult 'Validation'
    if (-not $validation) { return @() }
    foreach ($t in @(ConvertTo-ItemList $validation.OnlyInSource)) { [PSCustomObject][ordered]@{ Type = 'Only in source'; Workbook = ''; Table = $t; Detail = '' } }
    foreach ($t in @(ConvertTo-ItemList $validation.OnlyInDestination)) { [PSCustomObject][ordered]@{ Type = 'Only in destination'; Workbook = ''; Table = $t; Detail = '' } }
    if ($validation.CrossQueryOk -eq $false) { [PSCustomObject][ordered]@{ Type = 'Cross query'; Workbook = ''; Table = ''; Detail = $validation.CrossQueryError } }
    if ($validation.PSObject.Properties['ScopeParameterResolves'] -and $validation.ScopeParameterResolves -eq $false) {
        [PSCustomObject][ordered]@{ Type = 'Scope parameter'; Workbook = ''; Table = ''; Detail = $validation.ScopeParameterError }
    }
    foreach ($f in @(ConvertTo-ItemList $validation.WorkbookFindings)) {
        foreach ($t in @(ConvertTo-ItemList $f.MissingInDestination)) { [PSCustomObject][ordered]@{ Type = 'Missing in destination'; Workbook = $f.DisplayName; Table = $t; Detail = '' } }
        foreach ($t in @(ConvertTo-ItemList $f.MissingInSource)) { [PSCustomObject][ordered]@{ Type = 'Missing in source'; Workbook = $f.DisplayName; Table = $t; Detail = '' } }
    }
}

function New-ScopePreflightHtml {
    param([object]$RunResult)
    $warnings = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Preflight.Warnings'))
    $errors = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Preflight.Errors'))
    $warnItems = foreach ($w in $warnings) { "<li>$(ConvertTo-ScopeHtmlEncoded $w)</li>" }
    $errItems = foreach ($e in $errors) { "<li>$(ConvertTo-ScopeHtmlEncoded $e)</li>" }
    $message = if ($warnings.Count -eq 0 -and $errors.Count -eq 0) { '<p class="muted">No preflight warnings or errors were recorded.</p>' } else { '' }
    return @"
  <h2 id="sec-preflight">Preflight</h2>
  <div class="preflight-grid">
    <div class="mini-card"><div class="mini-label">Passed</div><div class="mini-value">$([bool](Get-ScopeProp $RunResult 'Preflight.Passed'))</div></div>
    <div class="mini-card"><div class="mini-label">Cross-subscription</div><div class="mini-value">$([bool](Get-ScopeProp $RunResult 'Preflight.CrossSubscription'))</div></div>
    <div class="mini-card"><div class="mini-label">Cross-region</div><div class="mini-value">$([bool](Get-ScopeProp $RunResult 'Preflight.CrossRegion'))</div></div>
  </div>
  $message
  $(if ($warnings.Count -gt 0) { "<h3>Warnings</h3><ul>$($warnItems -join '')</ul>" } else { '' })
  $(if ($errors.Count -gt 0) { "<h3>Errors</h3><ul>$($errItems -join '')</ul>" } else { '' })
"@
}

function New-ScopeValidationHtml {
    param([object]$RunResult)
    $validation = Get-ScopeProp $RunResult 'Validation'
    if (-not $validation) { return '' }
    $rows = @(ConvertTo-ValidationRows -RunResult $RunResult)
    $scopeParameterAlert = ''
    if ($validation.PSObject.Properties['ScopeParameterResolves'] -and $validation.ScopeParameterResolves -eq $false) {
        $scopeParameterAlert = "<div class=""validation-alert""><strong>Scope parameter did not resolve.</strong> $(ConvertTo-ScopeHtmlEncoded $validation.ScopeParameterError)</div>"
    }
    return @"
  <h2 id="sec-validation">Validation</h2>
  <div class="preflight-grid">
    <div class="mini-card"><div class="mini-label">Cross-query OK</div><div class="mini-value">$([bool]$validation.CrossQueryOk)</div></div>
    $(if ($validation.PSObject.Properties['ScopeParameterResolves'] -and $null -ne $validation.ScopeParameterResolves) { "<div class=""mini-card""><div class=""mini-label"">Scope parameter resolves</div><div class=""mini-value"">$(ConvertTo-ScopeHtmlEncoded $validation.ScopeParameterResolves)</div></div>" } else { '' })
    <div class="mini-card"><div class="mini-label">Source tables</div><div class="mini-value">$(@(ConvertTo-ItemList $validation.SourceTables).Count)</div></div>
    <div class="mini-card"><div class="mini-label">Destination tables</div><div class="mini-value">$(@(ConvertTo-ItemList $validation.DestinationTables).Count)</div></div>
  </div>
  $scopeParameterAlert
  $(if ($validation.CrossQueryError) { "<p class=""muted"">$(ConvertTo-ScopeHtmlEncoded $validation.CrossQueryError)</p>" } else { '' })
  $(New-ScopeDetailTable -Title 'Validation Findings' -Rows $rows)
"@
}

function New-ScopeReadinessHtml {
    param([object]$RunResult)
    $readiness = Get-ScopeDecommissionReadiness -RunResult $RunResult
    return @"
  <h2 id="sec-readiness">Decommission Readiness</h2>
  <div class="readiness tone-$($readiness.Tone)">$(ConvertTo-ScopeHtmlEncoded $readiness.Message)</div>
"@
}

function New-ScopeSummaryHtml {
    <#
    .SYNOPSIS
        Writes the self-contained HTML summary for a workbook scope run.
    .DESCRIPTION
        Produces Scope-Summary.html with embedded CSS and JavaScript only. Values
        that can originate from Azure, including workbook names, are HTML-encoded.
    .PARAMETER RunResult
        The RunResult object produced by the workbook scope assistant.
    .PARAMETER OutputPath
        Directory where Scope-Summary.html should be written.
    .PARAMETER NoDetailTables
        Suppresses expandable detail tables for workbook, error, and validation rows.
    .OUTPUTS
        The full path to the written HTML file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$RunResult,
        [Parameter(Mandatory)][string]$OutputPath,
        [switch]$NoDetailTables
    )

    if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
    $kpis = Get-ScopeKpis -RunResult $RunResult
    $details = [ordered]@{}
    if (-not $NoDetailTables) {
        $details['Workbooks'] = @(ConvertTo-WorkbookRows -RunResult $RunResult)
        $details['Errors'] = @(ConvertTo-ErrorRows -RunResult $RunResult)
        if (Get-ScopeProp $RunResult 'Validation') { $details['Validation'] = @(ConvertTo-ValidationRows -RunResult $RunResult) }
    }
    $hasDetails = @($details.Keys).Count -gt 0
    $kpiAnchor = @{ 'Failed' = 'Workbooks'; 'Errors' = 'Errors' }
    $kpiTone = @{ 'Scoped to both' = 'good'; 'Reverted' = 'good'; 'Failed' = 'bad'; 'Skipped' = 'warn'; 'Errors' = 'bad' }
    $cards = foreach ($k in @($kpis.Keys)) {
        $anchor = ''
        if ($hasDetails -and $kpiAnchor.ContainsKey($k) -and $details.Contains($kpiAnchor[$k])) { $anchor = ConvertTo-ScopeSlug $kpiAnchor[$k] }
        $tone = $kpiTone[$k]
        if (-not $tone) { $tone = 'default' }
        if ($tone -in @('bad', 'warn') -and (ConvertTo-ScopeNumber $kpis[$k]) -eq 0) { $tone = 'default' }
        New-ScopeKpiCard -Label $k -Value $kpis[$k] -Anchor $anchor -Tone $tone
    }
    $charts = @(
        New-ScopeBarChart -Title 'Workbooks by Outcome' -Pairs (Get-ScopeActionBreakdown -Results (Get-ScopeProp $RunResult 'Results')) -Color '#7c3aed'
    )
    $detailHtml = ''
    if ($hasDetails) {
        $jumpLinks = [System.Collections.Generic.List[string]]::new()
        $tables = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $details.GetEnumerator()) {
            $slug = ConvertTo-ScopeSlug ([string]$entry.Key)
            $rows = @(ConvertTo-ItemList $entry.Value)
            $jumpLinks.Add("<a href=""#$slug"">$(ConvertTo-ScopeHtmlEncoded $entry.Key) <span class=""count"">$($rows.Count)</span></a>") | Out-Null
            $tables.Add((New-ScopeDetailTable -Title ([string]$entry.Key) -Rows $rows)) | Out-Null
        }
        $detailHtml = @"
  <h2>Detailed Results</h2>
  <p class="muted">Click a section to expand. Use the filter box to search and click a column header to sort. Same facts as the Excel or CSV export.</p>
  <div class="jump">$($jumpLinks -join '')</div>
  $($tables -join "`n")
"@
    }

    $modeRaw = [string](Get-ScopeProp $RunResult 'Mode')
    $mode = if ($modeRaw -eq 'DryRun') { 'DRY RUN (no changes made)' } elseif ($modeRaw) { $modeRaw } else { 'N/A' }
    $modeCls = if ($modeRaw -eq 'DryRun') { 'mode-dry' } else { 'mode-exec' }
    $dryBanner = if ($modeRaw -eq 'DryRun') { '<div class="dry-banner">This is a dry run. No workbook JSON was changed. Re-run with -Execute to apply these changes.</div>' } else { '' }
    $duration = ConvertTo-ScopeHtmlEncoded (Format-RunDuration (Get-ScopeProp $RunResult 'Duration'))
    $generated = ConvertTo-ScopeHtmlEncoded (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $operation = ConvertTo-ScopeHtmlEncoded (Get-ScopeProp $RunResult 'Operation' 'N/A')
    $scopeMode = ConvertTo-ScopeHtmlEncoded (Get-ScopeModeLabel -RunResult $RunResult)
    $version = ConvertTo-ScopeHtmlEncoded (Get-ScopeProp $RunResult 'ToolVersion' 'N/A')
    $srcWs = ConvertTo-ScopeHtmlEncoded (Get-ScopeProp $RunResult 'Source.WorkspaceName')
    $srcRg = ConvertTo-ScopeHtmlEncoded (Get-ScopeProp $RunResult 'Source.ResourceGroupName')
    $srcSub = ConvertTo-ScopeHtmlEncoded (Get-ScopeProp $RunResult 'Source.SubscriptionId')
    $dstWs = ConvertTo-ScopeHtmlEncoded (Get-ScopeProp $RunResult 'Destination.WorkspaceName')
    $dstRg = ConvertTo-ScopeHtmlEncoded (Get-ScopeProp $RunResult 'Destination.ResourceGroupName')
    $dstSub = ConvertTo-ScopeHtmlEncoded (Get-ScopeProp $RunResult 'Destination.SubscriptionId')
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Workbook Scope — $srcWs → $dstWs</title>
<style>
  :root { --bg:#0f172a; --card:#1e293b; --muted:#94a3b8; --text:#e2e8f0; --accent:#38bdf8;
          --good:#34d399; --warn:#fbbf24; --bad:#f87171; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:Segoe UI,Arial,sans-serif; background:var(--bg); color:var(--text); }
  header { padding:28px 32px; background:linear-gradient(90deg,#0ea5e9,#6366f1); color:#fff; }
  header h1 { margin:0 0 6px; font-size:24px; }
  header .meta { font-size:13px; opacity:.9; }
  .badge { display:inline-block; border-radius:6px; padding:2px 10px; font-size:12px; font-weight:700; letter-spacing:.4px; }
  .mode-dry { background:#fef3c7; color:#92400e; }
  .mode-exec { background:#dcfce7; color:#166534; }
  main { padding:24px 32px 60px; max-width:1200px; margin:0 auto; }
  h2 { border-bottom:1px solid #334155; padding-bottom:8px; margin-top:36px; }
  .dry-banner { background:#451a03; border:1px solid #f59e0b; color:#fde68a; border-radius:10px; padding:12px 16px; margin:18px 0; font-weight:600; }
  .readiness, .validation-alert { background:var(--card); border:1px solid #334155; border-left:4px solid var(--accent); border-radius:10px; padding:14px 18px; margin:14px 0; line-height:1.55; }
  .readiness.tone-good { border-left-color:var(--good); }
  .readiness.tone-warn { border-left-color:var(--warn); }
  .readiness.tone-bad, .validation-alert { border-left-color:var(--bad); }
  .flow { display:flex; flex-wrap:wrap; align-items:center; gap:14px; margin:18px 0 4px; }
  .ws { background:var(--card); border:1px solid #334155; border-radius:12px; padding:14px 18px; flex:1; min-width:260px; }
  .ws .ws-role { font-size:11px; text-transform:uppercase; letter-spacing:.6px; color:var(--muted); }
  .ws .ws-name { font-size:17px; font-weight:600; margin-top:2px; }
  .ws .ws-sub { font-size:12px; color:var(--muted); margin-top:4px; word-break:break-all; }
  .arrow { font-size:26px; color:var(--accent); }
  .kpis, .preflight-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(180px,1fr)); gap:16px; }
  .kpi, .mini-card { background:var(--card); border-radius:12px; padding:18px; border:1px solid #334155; }
  .kpi-value { font-size:30px; font-weight:700; color:var(--accent); }
  .kpi-label, .mini-label { font-size:13px; color:var(--muted); margin-top:4px; }
  .mini-value { font-size:20px; font-weight:700; color:var(--accent); }
  .kpi.tone-good .kpi-value { color:var(--good); }
  .kpi.tone-warn .kpi-value { color:var(--warn); }
  .kpi.tone-bad .kpi-value { color:var(--bad); }
  .charts { display:grid; grid-template-columns:repeat(auto-fill,minmax(480px,1fr)); gap:20px; }
  .chart { background:var(--card); border-radius:12px; padding:18px 20px; border:1px solid #334155; }
  .chart h3 { margin:0 0 14px; font-size:15px; }
  .bar-row { display:grid; grid-template-columns:180px 1fr 60px; align-items:center; gap:10px; margin:6px 0; }
  .bar-label { font-size:12px; color:var(--muted); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .bar-track { background:#0f172a; border-radius:6px; height:16px; overflow:hidden; }
  .bar-fill { height:100%; border-radius:6px; }
  .bar-value { font-size:12px; text-align:right; font-variant-numeric:tabular-nums; }
  .muted { color:var(--muted); font-size:13px; }
  .detail { background:var(--card); border:1px solid #334155; border-radius:10px; margin:10px 0; padding:0 16px; }
  .detail > summary { cursor:pointer; padding:14px 0; font-size:15px; font-weight:600; list-style:none; }
  .detail > summary::-webkit-details-marker { display:none; }
  .detail > summary::before { content:'\25B8'; display:inline-block; margin-right:8px; color:var(--accent); transition:transform .15s; }
  .detail[open] > summary::before { transform:rotate(90deg); }
  .count { display:inline-block; background:#0f172a; color:var(--accent); border-radius:10px; font-size:11px; padding:1px 8px; margin-left:6px; vertical-align:middle; }
  .tbl-search { width:100%; max-width:340px; margin:4px 0 12px; padding:7px 10px; border-radius:8px; border:1px solid #334155; background:#0f172a; color:var(--text); font-size:13px; }
  .tbl-wrap { overflow:auto; max-height:460px; border:1px solid #263349; border-radius:8px; margin-bottom:16px; }
  table.detail-table { border-collapse:collapse; width:100%; font-size:12px; }
  table.detail-table th, table.detail-table td { text-align:left; padding:7px 10px; border-bottom:1px solid #263349; white-space:nowrap; }
  table.detail-table thead th { position:sticky; top:0; background:#172033; cursor:pointer; user-select:none; z-index:1; }
  table.detail-table tbody tr.row-bad td:first-child { border-left:3px solid var(--bad); color:var(--bad); }
  table.detail-table tbody tr.row-warn td:first-child { border-left:3px solid var(--warn); }
  .sort-ind { color:var(--accent); font-size:10px; }
  .jump { display:flex; flex-wrap:wrap; gap:8px; margin:12px 0 20px; }
  .jump a, a.kpi-link { text-decoration:none; color:inherit; }
  .jump a { font-size:12px; color:var(--accent); background:var(--card); border:1px solid #334155; border-radius:8px; padding:6px 10px; }
  ol.steps { list-style:none; counter-reset:step; padding:0; margin:14px 0 0; }
  ol.steps > li.step { counter-increment:step; position:relative; background:var(--card); border:1px solid #334155; border-left:4px solid var(--muted); border-radius:10px; padding:14px 18px 14px 56px; margin:10px 0; }
  ol.steps > li.step::before { content:counter(step); position:absolute; left:16px; top:14px; width:26px; height:26px; border-radius:50%; background:#0f172a; color:var(--accent); font-size:13px; font-weight:700; display:flex; align-items:center; justify-content:center; }
  li.step.tone-bad { border-left-color:var(--bad); }
  li.step.tone-warn { border-left-color:var(--warn); }
  li.step.tone-good { border-left-color:var(--good); }
  li.step.tone-info { border-left-color:var(--accent); }
  .step-title { font-size:15px; font-weight:600; margin-bottom:5px; }
  .step-detail { font-size:13px; color:var(--muted); line-height:1.55; }
  footer { text-align:center; color:var(--muted); font-size:12px; padding:20px; }
</style>
</head>
<body>
<header>
  <h1>Sentinel Workbook Scope Assistant</h1>
  <div class="meta"><span class="badge $modeCls">$(ConvertTo-ScopeHtmlEncoded $mode)</span> &nbsp;|&nbsp; Operation: $operation &nbsp;|&nbsp; Scope mode: $scopeMode &nbsp;|&nbsp; Duration: $duration &nbsp;|&nbsp; Generated: $generated &nbsp;|&nbsp; Version: $version</div>
</header>
<main>
  $dryBanner
  <div class="flow">
    <div class="ws"><div class="ws-role">Source</div><div class="ws-name">$srcWs</div><div class="ws-sub">RG: $srcRg<br>Sub: $srcSub</div></div>
    <div class="arrow">&#8596;</div>
    <div class="ws"><div class="ws-role">Destination</div><div class="ws-name">$dstWs</div><div class="ws-sub">RG: $dstRg<br>Sub: $dstSub</div></div>
  </div>
  <h2>Scope Outcome</h2>
  <div class="kpis">$($cards -join "`n")</div>
  $(New-ScopeReadinessHtml -RunResult $RunResult)
  <h2>Breakdowns</h2>
  <div class="charts">$($charts -join "`n")</div>
  $(New-ScopeNextStepsHtml -Steps (Get-ScopeNextSteps -RunResult $RunResult))
  $(New-ScopePreflightHtml -RunResult $RunResult)
  $(New-ScopeValidationHtml -RunResult $RunResult)
  $detailHtml
</main>
<footer>Generated by the Sentinel Workbook Scope Assistant. The tool changes workbook crossComponentResources scope; it does not rewrite KQL.</footer>
<script>
function filterTable(id, q) {
  q = (q || '').toLowerCase();
  var rows = document.querySelectorAll('#' + id + ' tbody tr');
  for (var i = 0; i < rows.length; i++) rows[i].style.display = rows[i].textContent.toLowerCase().indexOf(q) > -1 ? '' : 'none';
}
function sortTable(id, col, th) {
  var tbody = document.getElementById(id).tBodies[0], rows = Array.prototype.slice.call(tbody.rows), asc = th.getAttribute('data-asc') !== 'true';
  var heads = th.parentNode.children;
  for (var h = 0; h < heads.length; h++) { heads[h].removeAttribute('data-asc'); var si = heads[h].querySelector('.sort-ind'); if (si) si.textContent = ''; }
  th.setAttribute('data-asc', asc);
  rows.sort(function(a,b){ var x=a.cells[col].textContent.trim(), y=b.cells[col].textContent.trim(), nx=parseFloat(x.replace(/,/g,'')), ny=parseFloat(y.replace(/,/g,'')); var both=x!==''&&y!==''&&!isNaN(nx)&&!isNaN(ny); var cmp=both?nx-ny:x.toLowerCase().localeCompare(y.toLowerCase()); return asc?cmp:-cmp; });
  for (var r = 0; r < rows.length; r++) tbody.appendChild(rows[r]);
  var ind = th.querySelector('.sort-ind'); if (ind) ind.textContent = asc ? ' \u25B2' : ' \u25BC';
}
</script>
</body>
</html>
"@
    $path = Join-Path $OutputPath 'Scope-Summary.html'
    $html | Set-Content -Path $path -Encoding UTF8
    return $path
}

Export-ModuleMember -Function @(
    'New-ScopeSummaryHtml'
)
