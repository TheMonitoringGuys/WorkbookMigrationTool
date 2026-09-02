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

function Format-ScopeReportCell {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    $text = ([string]$Value) -replace '\r?\n', ' '
    $text = $text -replace '\|', '\|'
    return $text.Trim()
}

function Format-ScopeReportInline {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return (([string]$Value) -replace '\r?\n', ' ').Trim()
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

function Get-ScopeResultSum {
    param([object[]]$Results, [Parameter(Mandatory)][string]$Property)
    $sum = 0
    foreach ($r in @(ConvertTo-ItemList $Results)) {
        $value = Get-ScopeProp $r $Property 0
        if ($null -ne $value) { $sum += [int]$value }
    }
    return $sum
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
        return "Decommission readiness is unknown for failed workbook(s): $($failedNames -join ', '). Fix those failures before turning off the source workspace."
    }

    if ($operation -eq 'Revert' -or $reverted.Count -gt 0) {
        return 'The workbooks are back to destination-only scope and the source workspace can be removed.'
    }

    if ($scoped.Count -gt 0 -and $scopeMode -eq 'SelfHealing') {
        return 'The scoped workbooks will keep working when the source workspace is deleted; no revert is required first.'
    }

    if ($scoped.Count -gt 0) {
        return "The scoped workbooks will stop rendering when the source workspace is deleted and must be reverted first. Revert command: $(Get-ScopeRevertCommand -RunResult $RunResult)"
    }

    return 'No scoped workbook results were recorded, so decommission readiness cannot be determined from this run.'
}

function New-ScopeReportTable {
    param(
        [string[]]$Header,
        [System.Collections.Generic.List[object[]]]$Row
    )
    if ($null -eq $Row -or $Row.Count -eq 0) { return $null }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('| ' + (($Header | ForEach-Object { Format-ScopeReportCell $_ }) -join ' | ') + ' |')
    [void]$sb.AppendLine('|' + (($Header | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in $Row) {
        [void]$sb.AppendLine('| ' + (($r | ForEach-Object { Format-ScopeReportCell $_ }) -join ' | ') + ' |')
    }
    return $sb.ToString()
}

function Get-ScopeEvidence {
    <#
    .SYNOPSIS
        Classifies how strongly a result supports the claim that it is scoped.
    .DESCRIPTION
        'Scoped' is one word covering routes of very different strength, and the
        report used to present them identically. A workbook whose queries each
        carry the source workspace is a different claim from one where only the
        workbook-level fallback was extended - the latter is silently overridden
        by any query that carries its own scope.

        Reporting them the same way is how a run can look completely clean while
        a workbook returns no historical data.

          Per-query     queries now name the source directly. Strongest.
          Picker        a workspace picker was patched, or the injected
                        reference was appended beside the customer's own. Real,
                        but it depends on the picker resolving at render time.
          Fallback only ONLY the workbook default was extended. Weakest: any
                        query carrying its own scope ignores it.
          None          nothing changed, yet the action claims otherwise.
    .OUTPUTS
        Hashtable with Label, Tone ('good'|'warn'|'bad') and Detail.
    #>
    [CmdletBinding()]
    param([object]$Result)

    $added = [int](Get-ScopeProp $Result 'Added' 0)
    $replaced = [int](Get-ScopeProp $Result 'Replaced' 0)
    $patched = [int](Get-ScopeProp $Result 'ParametersPatched' 0)
    $viaPicker = [int](Get-ScopeProp $Result 'ScopedViaPicker' 0)
    $fallback = Get-ScopeProp $Result 'FallbackUpdated' $false

    $perQuery = $added + $replaced
    $pickerWork = $patched + $viaPicker

    if ($perQuery -gt 0) {
        return @{ Label = 'Per-query'; Tone = 'good'; Detail = "$perQuery quer(y/ies) now name the source workspace directly." }
    }
    if ($pickerWork -gt 0) {
        return @{ Label = 'Picker'; Tone = 'good'; Detail = "$pickerWork parameter(s) carry the source workspace. Confirm the picker resolves for viewers." }
    }
    if ($fallback) {
        return @{ Label = 'Fallback only'; Tone = 'warn'; Detail = 'Only the workbook-level default was extended. Any query carrying its own scope ignores it.' }
    }
    return @{ Label = 'None'; Tone = 'bad'; Detail = 'No scope change was recorded, so this workbook has no evidence of being scoped.' }
}

function Get-ScopeKpis {
    param([object]$RunResult)
    $results = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Results'))
    $errors = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Errors'))
    $countBy = {
        param($Pattern)
        @($results | Where-Object { (Get-NormalizedAction $_.Action) -match $Pattern }).Count
    }
    $parametersPatched = Get-ScopeResultSum -Results $results -Property 'ParametersPatched'
    $scopedViaPicker = Get-ScopeResultSum -Results $results -Property 'ScopedViaPicker'
    $kpis = [ordered]@{
        'Workbooks processed' = @($results).Count
        'Scoped to both'      = & $countBy '^Scoped$'
        'Reverted'            = & $countBy '^Reverted$'
        'Already scoped'      = & $countBy '^AlreadyScoped$'
        'Not scoped'          = & $countBy '^NotScoped$'
        'Skipped'             = & $countBy '^Skipped$'
        'Failed'              = & $countBy '^Failed$'
        'Eligible queries'    = Get-ScopeResultSum -Results $results -Property 'Eligible'
        'Ineligible queries'  = Get-ScopeResultSum -Results $results -Property 'Ineligible'
    }
    if ($parametersPatched -gt 0) { $kpis['Parameters patched'] = $parametersPatched }
    if ($scopedViaPicker -gt 0) { $kpis['Scoped via existing picker'] = $scopedViaPicker }

    # Surfaced only when it applies, and only for workbooks claiming to be
    # scoped. A count here means some workbook's clean-looking result rests on
    # the weakest available evidence.
    $weak = @($results | Where-Object {
            (Get-NormalizedAction $_.Action) -in @('Scoped', 'AlreadyScoped') -and
            (Get-ScopeEvidence -Result $_).Tone -ne 'good'
        }).Count
    if ($weak -gt 0) { $kpis['Scoped on weak evidence'] = $weak }

    $kpis['Collected errors'] = @($errors).Count
    return $kpis
}

function Get-ScopeNextSteps {
    param([object]$RunResult)
    $results = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Results'))
    $validation = Get-ScopeProp $RunResult 'Validation'
    $errors = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Errors'))
    $preflightWarnings = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Preflight.Warnings'))
    $preflightErrors = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Preflight.Errors'))
    $sourceName = [string](Get-ScopeProp $RunResult 'Source.WorkspaceName' 'source workspace')
    $destName = [string](Get-ScopeProp $RunResult 'Destination.WorkspaceName' 'destination workspace')
    $mode = [string](Get-ScopeProp $RunResult 'Mode')
    $operation = [string](Get-ScopeProp $RunResult 'Operation')
    $scopeMode = Get-ScopeModeLabel -RunResult $RunResult

    $steps = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($Title, $Detail, $Count)
        $steps.Add([PSCustomObject]@{ Order = $steps.Count + 1; Title = $Title; Detail = $Detail; Count = $Count }) | Out-Null
    }

    if ($mode -eq 'DryRun') {
        & $add 'Run the change for real' 'Exact command: re-run the same command that produced this report and add -Execute, or replace -DryRun with -Execute. Dry run is the default, so no workbook was changed in this run.' 0
    }

    $changed = @($results | Where-Object { (Get-NormalizedAction $_.Action) -in @('Scoped', 'Reverted') })
    $scoped = @($results | Where-Object { (Get-NormalizedAction $_.Action) -eq 'Scoped' })
    if ($scoped.Count -gt 0) {
        # The backtick before $ escapes it, so the variable would print literally.
        # Build the code-fenced names first, then interpolate them.
        & $add 'Confirm viewer permissions on both workspaces' "Workbook viewers now need Log Analytics Reader on both ``$sourceName`` and ``$destName``. The tool sets each query item's crossComponentResources array so the Workbooks engine unions both workspaces; it does not rewrite KQL." $scoped.Count
        if ($scopeMode -eq 'Literal') {
            & $add 'Revert literal scope before decommissioning' "Literal scoped workbooks will stop rendering when the source workspace is deleted. Before removing it, run: ``$(Get-ScopeRevertCommand -RunResult $RunResult)``." $scoped.Count
        }
        else {
            & $add 'Treat revert as optional tidy-up' 'Self-healing scoped workbooks keep rendering after the source workspace is deleted. A later revert is optional tidy-up if you want to remove the hidden source parameter and scope manifest.' $scoped.Count
        }
    }

    $reverted = @($results | Where-Object { (Get-NormalizedAction $_.Action) -eq 'Reverted' })
    if ($reverted.Count -gt 0) {
        & $add 'Verify destination-only workbook scope' "These workbooks were reverted to ``$destName`` only. Open representative workbooks and confirm queries still render after source workspace access is removed." $reverted.Count
    }

    if ([bool](Get-ScopeProp $RunResult 'Preflight.CrossSubscription')) {
        & $add 'Check cross-subscription workbook pickers' "The source and destination workspaces are in different subscriptions. Any workbook picker or Azure portal view used with these workbooks must allow both subscriptions." 0
    }

    if ([bool](Get-ScopeProp $RunResult 'Preflight.CrossRegion')) {
        & $add 'Review cross-region query expectations' "The source and destination workspaces are in different regions. Cross-resource workbook queries are expected to work, but latency and table availability should be checked with real users." 0
    }

    $onlySource = @()
    if ($validation) { $onlySource = @(ConvertTo-ItemList $validation.OnlyInSource) }
    if ($onlySource.Count -gt 0) {
        & $add 'Connect missing destination data sources' ("These tables exist only in the source workspace: " + ($onlySource -join ', ') + ". The combined workbook can show source data now, but destination-only operation needs these tables populated before the source is decommissioned.") $onlySource.Count
    }

    $onlyDest = @()
    if ($validation) { $onlyDest = @(ConvertTo-ItemList $validation.OnlyInDestination) }
    if ($onlyDest.Count -gt 0) {
        & $add 'Review tables found only in the destination' ("These tables exist only in the destination workspace: " + ($onlyDest -join ', ') + ". That may be expected after migration, but it is worth confirming the source is not missing required connectors.") $onlyDest.Count
    }

    if ($validation -and $validation.CrossQueryOk -eq $false) {
        & $add 'Fix cross-workspace query validation' "The validation query failed: $($validation.CrossQueryError). Resolve this before relying on combined workbook views." 1
    }

    if ($validation -and $validation.PSObject.Properties['ScopeParameterResolves'] -and $validation.ScopeParameterResolves -eq $false) {
        & $add 'Fix self-healing scope parameter validation' "The hidden source parameter did not resolve: $($validation.ScopeParameterError). In self-healing mode this silently hides source data, so resolve it before relying on combined workbook views." 1
    }

    $failed = @($results | Where-Object { (Get-NormalizedAction $_.Action) -eq 'Failed' })
    if ($failed.Count -gt 0) {
        $names = @($failed | ForEach-Object { if ($_.DisplayName) { $_.DisplayName } else { $_.WorkbookId } }) -join ', '
        & $add 'Re-run failed workbooks after fixing the error' "The failed workbook(s) were: $names. The per-workbook table and errors section include the failure reason; fix that issue and re-run the $operation operation." $failed.Count
    }

    if ($preflightErrors.Count -gt 0) {
        & $add 'Resolve preflight errors' 'Preflight errors mean the run could not prove the workspace inputs are ready. Resolve the listed errors before applying workbook scope changes.' $preflightErrors.Count
    }
    elseif ($preflightWarnings.Count -gt 0) {
        & $add 'Review preflight warnings' 'The run continued with warnings. Review them before treating the scoped workbooks as production-ready.' $preflightWarnings.Count
    }

    if ($errors.Count -gt 0) {
        & $add 'Work through collected errors' 'Each collected error names the component, message, and remediation when available. These are the best starting points for a targeted re-run.' $errors.Count
    }

    if ($steps.Count -eq 0) {
        & $add 'No follow-up actions identified' 'This run did not produce failures, validation gaps, warnings, or permission follow-up beyond normal operational review.' 0
    }

    return $steps.ToArray()
}

function New-ScopeReportContent {
    param([object]$RunResult)
    $results = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Results'))
    $validation = Get-ScopeProp $RunResult 'Validation'
    $errors = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Errors'))
    $mode = [string](Get-ScopeProp $RunResult 'Mode')
    $operation = [string](Get-ScopeProp $RunResult 'Operation')
    $duration = Format-RunDuration (Get-ScopeProp $RunResult 'Duration')
    $actionHeader = if ($mode -eq 'DryRun') { 'Planned action' } else { 'Action' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Sentinel Workbook Scope Report')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Mode:** $(if ($mode -eq 'DryRun') { 'DRY RUN (no changes made)' } elseif ($mode) { $mode } else { 'N/A' })")
    [void]$sb.AppendLine("**Operation:** $(if ($operation) { $operation } else { 'N/A' })")
    [void]$sb.AppendLine("**Scope mode:** $(Format-ScopeReportInline (Get-ScopeModeLabel -RunResult $RunResult))")
    [void]$sb.AppendLine("**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $startTime = Get-ScopeProp $RunResult 'StartTime'
    $endTime = Get-ScopeProp $RunResult 'EndTime'
    if ($startTime) { [void]$sb.AppendLine("**Started:** $(([datetime]$startTime).ToString('yyyy-MM-dd HH:mm:ss'))") }
    if ($endTime) { [void]$sb.AppendLine("**Completed:** $(([datetime]$endTime).ToString('yyyy-MM-dd HH:mm:ss'))") }
    [void]$sb.AppendLine("**Duration:** $duration")
    [void]$sb.AppendLine("**Tool version:** $(Format-ScopeReportInline (Get-ScopeProp $RunResult 'ToolVersion' 'N/A'))")
    [void]$sb.AppendLine('')
    if ($mode -eq 'DryRun') {
        [void]$sb.AppendLine('> **This was a preview.** No workbook JSON was changed. Outcomes below describe what the tool would do.')
    }
    else {
        [void]$sb.AppendLine('> **Changes were applied** to workbook scope configuration in the destination workspace.')
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('## Workspaces')
    [void]$sb.AppendLine('')
    $wsRows = [System.Collections.Generic.List[object[]]]::new()
    $wsRows.Add(@('**Source**', (Get-ScopeProp $RunResult 'Source.SubscriptionId'), (Get-ScopeProp $RunResult 'Source.ResourceGroupName'), (Get-ScopeProp $RunResult 'Source.WorkspaceName'), (Get-ScopeProp $RunResult 'Source.Location'), (Get-ScopeProp $RunResult 'Source.ResourceId'))) | Out-Null
    $wsRows.Add(@('**Destination**', (Get-ScopeProp $RunResult 'Destination.SubscriptionId'), (Get-ScopeProp $RunResult 'Destination.ResourceGroupName'), (Get-ScopeProp $RunResult 'Destination.WorkspaceName'), (Get-ScopeProp $RunResult 'Destination.Location'), (Get-ScopeProp $RunResult 'Destination.ResourceId'))) | Out-Null
    [void]$sb.AppendLine((New-ScopeReportTable -Header @('', 'Subscription', 'Resource Group', 'Workspace', 'Location', 'Resource ID') -Row $wsRows))

    [void]$sb.AppendLine('## KPI Summary')
    [void]$sb.AppendLine('')
    $kpiRows = [System.Collections.Generic.List[object[]]]::new()
    foreach ($k in (Get-ScopeKpis -RunResult $RunResult).GetEnumerator()) { $kpiRows.Add(@($k.Key, $k.Value)) | Out-Null }
    [void]$sb.AppendLine((New-ScopeReportTable -Header @('Measure', 'Count') -Row $kpiRows))

    [void]$sb.AppendLine('## Decommission Readiness')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine((Format-ScopeReportInline (Get-ScopeDecommissionReadiness -RunResult $RunResult)))
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('## Next Steps')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Derived from this run's results and listed in the order they should be tackled.")
    [void]$sb.AppendLine('')
    foreach ($s in @(Get-ScopeNextSteps -RunResult $RunResult)) {
        $suffix = if ($s.Count -and [int]$s.Count -gt 0) { " ($($s.Count))" } else { '' }
        [void]$sb.AppendLine("$($s.Order). **$(Format-ScopeReportInline $s.Title)$suffix**")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("   $(Format-ScopeReportInline $s.Detail)")
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine('## Workbook Results')
    [void]$sb.AppendLine('')
    $wbRows = [System.Collections.Generic.List[object[]]]::new()
    foreach ($r in $results) {
        $evidence = if ((Get-NormalizedAction $r.Action) -in @('Scoped', 'AlreadyScoped')) {
            (Get-ScopeEvidence -Result $r).Label
        } else { '' }
        $wbRows.Add(@($r.DisplayName, (Format-ActionLabel $r.Action), $evidence, $r.Eligible, $r.Added, $r.Replaced, (Get-ScopeProp $r 'ParametersPatched' 0), (Get-ScopeProp $r 'ScopedViaPicker' 0), $r.Reason)) | Out-Null
    }
    if ($wbRows.Count -gt 0) {
        [void]$sb.AppendLine((New-ScopeReportTable -Header @('Workbook', $actionHeader, 'Evidence', 'Eligible', 'Added', 'Replaced', 'Parameters patched', 'Scoped via existing picker', 'Reason') -Row $wbRows))

        # Named individually, because "3 workbooks on weak evidence" is not
        # actionable and this is the report someone reads when the dashboards
        # disagree with the run.
        $weakRows = @($results | Where-Object {
                (Get-NormalizedAction $_.Action) -in @('Scoped', 'AlreadyScoped') -and
                (Get-ScopeEvidence -Result $_).Tone -ne 'good'
            })
        if ($weakRows.Count -gt 0) {
            [void]$sb.AppendLine('### Workbooks scoped on weak evidence')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('These report success, but not by the strongest route. Check them first if historical data is missing.')
            [void]$sb.AppendLine('')
            foreach ($r in $weakRows) {
                $e = Get-ScopeEvidence -Result $r
                [void]$sb.AppendLine("- **$(Format-ScopeReportInline $r.DisplayName)** — $($e.Label): $(Format-ScopeReportInline $e.Detail)")
            }
            [void]$sb.AppendLine('')
        }
    }
    else {
        [void]$sb.AppendLine('No workbook results were recorded.')
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine('## Ineligible Queries')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Ineligible queries are intentionally skipped because they are not Log Analytics queries: Resource Graph, Application Insights, metrics, and similar query types do not use workbook Log Analytics crossComponentResources scope.')
    [void]$sb.AppendLine('')
    $inRows = [System.Collections.Generic.List[object[]]]::new()
    foreach ($r in $results | Where-Object { [int]$_.Ineligible -gt 0 }) { $inRows.Add(@($r.DisplayName, $r.Ineligible)) | Out-Null }
    if ($inRows.Count -gt 0) { [void]$sb.AppendLine((New-ScopeReportTable -Header @('Workbook', 'Ineligible queries') -Row $inRows)) }
    else { [void]$sb.AppendLine('No ineligible queries were reported.'); [void]$sb.AppendLine('') }

    [void]$sb.AppendLine('## Preflight')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- **Passed:** $([bool](Get-ScopeProp $RunResult 'Preflight.Passed'))")
    [void]$sb.AppendLine("- **Cross-subscription:** $([bool](Get-ScopeProp $RunResult 'Preflight.CrossSubscription'))")
    [void]$sb.AppendLine("- **Cross-region:** $([bool](Get-ScopeProp $RunResult 'Preflight.CrossRegion'))")
    [void]$sb.AppendLine('')
    $warnings = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Preflight.Warnings'))
    $pfErrors = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Preflight.Errors'))
    if ($warnings.Count -gt 0) {
        [void]$sb.AppendLine('### Warnings')
        foreach ($w in $warnings) { [void]$sb.AppendLine("- $(Format-ScopeReportInline $w)") }
        [void]$sb.AppendLine('')
    }
    if ($pfErrors.Count -gt 0) {
        [void]$sb.AppendLine('### Errors')
        foreach ($e in $pfErrors) { [void]$sb.AppendLine("- $(Format-ScopeReportInline $e)") }
        [void]$sb.AppendLine('')
    }
    if ($warnings.Count -eq 0 -and $pfErrors.Count -eq 0) { [void]$sb.AppendLine('No preflight warnings or errors were recorded.'); [void]$sb.AppendLine('') }

    if ($validation) {
        [void]$sb.AppendLine('## Validation')
        [void]$sb.AppendLine('')
        if ($validation.PSObject.Properties['ScopeParameterResolves'] -and $validation.ScopeParameterResolves -eq $false) {
            [void]$sb.AppendLine("> **Scope parameter did not resolve.** $(Format-ScopeReportInline $validation.ScopeParameterError)")
            [void]$sb.AppendLine('')
        }
        [void]$sb.AppendLine("- **Cross-query OK:** $([bool]$validation.CrossQueryOk)")
        if ($validation.CrossQueryError) { [void]$sb.AppendLine("- **Cross-query error:** $(Format-ScopeReportInline $validation.CrossQueryError)") }
        if ($validation.PSObject.Properties['ScopeParameterResolves'] -and $null -ne $validation.ScopeParameterResolves) {
            [void]$sb.AppendLine("- **Scope parameter resolves:** $($validation.ScopeParameterResolves)")
            if ($validation.ScopeParameterResolves -eq $false -and $validation.ScopeParameterError) {
                [void]$sb.AppendLine("- **Scope parameter error:** $(Format-ScopeReportInline $validation.ScopeParameterError)")
            }
        }
        [void]$sb.AppendLine("- **Source tables:** $(@(ConvertTo-ItemList $validation.SourceTables).Count)")
        [void]$sb.AppendLine("- **Destination tables:** $(@(ConvertTo-ItemList $validation.DestinationTables).Count)")
        [void]$sb.AppendLine("- **Only in source:** $(if (@(ConvertTo-ItemList $validation.OnlyInSource).Count -gt 0) { @(ConvertTo-ItemList $validation.OnlyInSource) -join ', ' } else { 'None' })")
        [void]$sb.AppendLine("- **Only in destination:** $(if (@(ConvertTo-ItemList $validation.OnlyInDestination).Count -gt 0) { @(ConvertTo-ItemList $validation.OnlyInDestination) -join ', ' } else { 'None' })")
        [void]$sb.AppendLine('')
        $findingRows = [System.Collections.Generic.List[object[]]]::new()
        foreach ($f in @(ConvertTo-ItemList $validation.WorkbookFindings)) {
            $findingRows.Add(@($f.DisplayName, (@(ConvertTo-ItemList $f.MissingInDestination) -join ', '), (@(ConvertTo-ItemList $f.MissingInSource) -join ', '))) | Out-Null
        }
        if ($findingRows.Count -gt 0) { [void]$sb.AppendLine((New-ScopeReportTable -Header @('Workbook', 'Missing in destination', 'Missing in source') -Row $findingRows)) }
    }

    [void]$sb.AppendLine('## Collected Errors')
    [void]$sb.AppendLine('')
    if ($errors.Count -gt 0) {
        foreach ($err in $errors) {
            [void]$sb.AppendLine("- **$(Format-ScopeReportInline $err.Component)**: $(Format-ScopeReportInline $err.Message)")
            if ($err.Remediation) { [void]$sb.AppendLine("  - *Remediation:* $(Format-ScopeReportInline $err.Remediation)") }
        }
        [void]$sb.AppendLine('')
    }
    else {
        [void]$sb.AppendLine('No collected errors were recorded.')
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine('*Generated by Sentinel Workbook Scope Assistant*')
    return $sb.ToString()
}

function New-ScopeReport {
    <#
    .SYNOPSIS
        Writes the Markdown scope report for a workbook scope run.
    .DESCRIPTION
        Renders the run header, KPI summary, workbook detail table, preflight and
        validation details, collected errors, and run-derived next steps to
        scope-report.md under the supplied output path.
    .PARAMETER RunResult
        The RunResult object produced by the workbook scope assistant.
    .PARAMETER OutputPath
        Directory where scope-report.md should be written.
    .OUTPUTS
        The full path to the written report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$RunResult,
        [Parameter(Mandatory)][string]$OutputPath
    )

    if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
    $path = Join-Path $OutputPath 'scope-report.md'
    New-ScopeReportContent -RunResult $RunResult | Set-Content -Path $path -Encoding UTF8
    return $path
}

Export-ModuleMember -Function @(
    'New-ScopeReport'
    # Exported so the classification can be tested directly. It is duplicated in
    # WorkbookScope.Html.psm1, and Html.Tests.ps1 asserts the same cases, so the
    # two cannot drift silently.
    'Get-ScopeEvidence'
)
