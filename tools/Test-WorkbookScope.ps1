<#
.SYNOPSIS
    Reports, for every workbook in the destination, whether it is genuinely scoped
    to both workspaces - and when it is not, why.

.DESCRIPTION
    Written for the case where a run reports success but the workbooks still show
    no data from the old environment, and only some of them are affected.

    "Scoped" is not one thing. A workbook query reaches its data by one of three
    routes, and each fails differently:

      literal    - the query carries the workspace IDs itself
      parameter  - the query points at a resource picker, and the picker holds the
                   IDs. A single-select picker cannot hold two, so it must also be
                   multi-select
      inherited  - the query carries no scope and uses the workbook-level
                   fallbackResourceIds

    A workbook can be correct on one route and broken on another, which is what
    makes this look like "solutions work, custom ones do not". This resolves each
    query by its own route and reports the truth per workbook.

    Read-only. It fetches workbooks and inspects them; it writes nothing and
    prints no token material.

.PARAMETER SubscriptionId
    Subscription containing the destination workspace.

.PARAMETER ResourceGroupName
    Resource group containing the destination workspace.

.PARAMETER WorkspaceName
    Destination Log Analytics workspace name.

.PARAMETER SourceWorkspaceName
    The old workspace's name. Matched by name, so this still works after the old
    workspace has been deleted.

.PARAMETER SourceSubscriptionId
    Subscription of the old workspace. Defaults to the destination's.

.PARAMETER SourceResourceGroupName
    Resource group of the old workspace. Defaults to the destination's.

.EXAMPLE
    ./tools/Test-WorkbookScope.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 `
        -ResourceGroupName my-rg -WorkspaceName new-workspace -SourceWorkspaceName old-workspace
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$WorkspaceName,
    [Parameter(Mandatory)][string]$SourceWorkspaceName,
    [string]$SourceSubscriptionId,
    [string]$SourceResourceGroupName
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root 'src'

# Import-Module -Force removes a module before re-importing it, and every module
# here self-imports its own dependencies the same way. Loading Discovery unloads
# the Api and Engine copies this script already had. Re-importing the base
# modules at the tail, deepest-first, rebinds them into this scope - the same
# order the orchestrator uses, and for the same reason.
foreach ($m in @('Discovery', 'Engine', 'Api', 'Common')) {
    Import-Module (Join-Path $srcDir "WorkbookScope.$m.psm1") -Force -DisableNameChecking
}

if (-not $SourceSubscriptionId) { $SourceSubscriptionId = $SubscriptionId }
if (-not $SourceResourceGroupName) { $SourceResourceGroupName = $ResourceGroupName }

$arm = Resolve-ArmEndpoint
$destId = Get-WorkspaceResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
$srcId = Get-WorkspaceResourceId -SubscriptionId $SourceSubscriptionId -ResourceGroupName $SourceResourceGroupName -WorkspaceName $SourceWorkspaceName

Write-Host ''
Write-Host 'Workbook scope audit' -ForegroundColor White
Write-Host ('-' * 100) -ForegroundColor DarkGray
Write-Host "  destination : $WorkspaceName"
Write-Host "  source      : $SourceWorkspaceName"
Write-Host ''

function Test-ListHasBoth {
    param([object]$List)
    $v = @(ConvertTo-SafeArray $List | ForEach-Object { [string]$_ })
    $hasDest = [bool]($v | Where-Object { $_ -ieq $destId })
    $hasSrc = [bool]($v | Where-Object { $_ -ieq $srcId })
    return ($hasDest -and $hasSrc)
}

$listUri = Get-WorkbooksUri -ArmEndpoint $arm -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -SourceId $destId -ExcludeContent
$stubs = @(Invoke-ScopeApiList -Uri $listUri -ThrottleDelayMs 50)

Write-Host ("  {0,-44} {1,-8} {2,-9} {3,-12} {4}" -f 'WORKBOOK', 'MIGRATED', 'PROCESSED', 'QUERIES', 'VERDICT') -ForegroundColor DarkGray

$rows = [System.Collections.Generic.List[object]]::new()

foreach ($stub in $stubs) {
    if (-not $stub.id) { continue }
    $wbId = ($stub.id -split '/')[-1]
    try {
        $wb = Invoke-ScopeApi -Method GET -ThrottleDelayMs 50 -Uri (
            Get-WorkbookUri -ArmEndpoint $arm -SubscriptionId $SubscriptionId `
                -ResourceGroupName $ResourceGroupName -WorkbookId $wbId -IncludeContent)
    }
    catch {
        Write-Warning "Could not read workbook '$wbId': $($_.Exception.Message)"
        continue
    }

    $name = Get-WorkbookDisplayName -Workbook $wb
    $migrated = Test-WorkbookIsMigrated -Workbook $wb

    $tree = ConvertFrom-SerializedWorkbook -Json ([string]$wb.properties.serializedData)
    $processed = [bool](Get-DualScopeManifest -Root $tree)
    $fallbackBoth = Test-ListHasBoth -List $tree['fallbackResourceIds']

    # Index parameters so a query that points at a picker can be resolved through it.
    $params = @{}
    foreach ($e in @(Get-WorkbookNode -Root $tree)) {
        if (-not (Test-IsParameterNode -Path $e.Path)) { continue }
        $n = [string]$e.Node['name']
        if ($n -and -not $params.ContainsKey($n)) { $params[$n] = $e.Node }
    }

    $ok = 0; $bad = 0
    $reasons = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($e in @(Get-WorkbookNode -Root $tree)) {
        $node = $e.Node
        if (-not (Test-EligibleQueryNode -Node $node)) { continue }

        switch (Get-ScopeReferenceKind -Node $node) {
            'Literal' {
                if (Test-ListHasBoth -List $node['crossComponentResources']) { $ok++ }
                else { $bad++; [void]$reasons.Add('query scoped to one workspace') }
            }
            'None' {
                # No scope of its own, so it uses the workbook-level default.
                if ($fallbackBoth) { $ok++ }
                else { $bad++; [void]$reasons.Add('inherits a single-workspace default') }
            }
            'Parameter' {
                $pn = Get-ReferencedParameterName -Node $node
                if (-not $pn -or -not $params.ContainsKey($pn)) {
                    $bad++; [void]$reasons.Add("points at a missing parameter '$pn'")
                    break
                }
                $p = $params[$pn]
                $valueBoth = Test-ListHasBoth -List $p['value']
                $multi = ($p['multiSelect'] -eq $true)
                if ($valueBoth -and $multi) { $ok++ }
                elseif ($valueBoth -and -not $multi) {
                    # Both IDs present but the picker can only surface one of them.
                    $bad++; [void]$reasons.Add("parameter '$pn' holds both but is not multi-select")
                }
                else {
                    $bad++; [void]$reasons.Add("parameter '$pn' does not hold both workspaces")
                }
            }
        }
    }

    $total = $ok + $bad
    $verdict = if ($total -eq 0) { 'no queries' }
    elseif ($bad -eq 0) { 'OK' }
    elseif ($ok -eq 0) { 'NOT SCOPED' }
    else { 'PARTIAL' }

    $rows.Add([PSCustomObject]@{
            Name = $name; Migrated = $migrated; Processed = $processed
            Ok = $ok; Bad = $bad; Total = $total; Verdict = $verdict
            Reasons = @($reasons)
        })

    $colour = switch ($verdict) { 'OK' { 'Green' } 'PARTIAL' { 'Yellow' } 'NOT SCOPED' { 'Red' } default { 'DarkGray' } }
    $short = if ($name.Length -gt 42) { $name.Substring(0, 42) } else { $name }
    Write-Host ("  {0,-44} {1,-8} {2,-9} {3,-12} " -f $short, $(if ($migrated) { 'yes' } else { 'no' }), $(if ($processed) { 'yes' } else { 'NO' }), "$ok/$total") -NoNewline
    Write-Host $verdict -ForegroundColor $colour
}

# ── Conclusions ───────────────────────────────────────────────────────────────
Write-Host ''
Write-Host ('-' * 100) -ForegroundColor DarkGray

$broken = @($rows | Where-Object { $_.Verdict -in @('NOT SCOPED', 'PARTIAL') })
$untouched = @($rows | Where-Object { -not $_.Processed -and $_.Total -gt 0 })
$skippedByTag = @($untouched | Where-Object { -not $_.Migrated })

if ($rows.Count -eq 0) {
    Write-Host 'No workbooks found bound to that workspace.' -ForegroundColor Yellow
    exit 2
}

if ($broken.Count -eq 0 -and $untouched.Count -eq 0) {
    Write-Host 'Every workbook is scoped to both workspaces.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'If data from the old workspace still does not appear, the workbooks are' -ForegroundColor Green
    Write-Host 'not the cause. The two usual reasons are:' -ForegroundColor Green
    Write-Host '  - the viewer lacks Log Analytics Reader on the OLD workspace. A' -ForegroundColor Green
    Write-Host '    cross-workspace query silently returns only the workspaces the caller' -ForegroundColor Green
    Write-Host '    can read, so this looks like missing data rather than an error.' -ForegroundColor Green
    Write-Host '  - the time range predates ingestion stopping in the old workspace.' -ForegroundColor Green
    Write-Host '    Widen it to a window that covers before the migration.' -ForegroundColor Green
    exit 0
}

if ($skippedByTag.Count -gt 0) {
    Write-Host "$($skippedByTag.Count) workbook(s) were never processed and carry no migration tag:" -ForegroundColor Yellow
    $skippedByTag | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  By default the tool only updates workbooks the Sentinel Migration' -ForegroundColor Yellow
    Write-Host '  Assistant created, identified by a MigratedFromWorkbookId tag. Workbooks' -ForegroundColor Yellow
    Write-Host '  built by hand, or installed from a Content Hub solution, do not carry it' -ForegroundColor Yellow
    Write-Host '  and are skipped - which is why only some workbooks show the old data.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Re-run including them:' -ForegroundColor Green
    Write-Host '     -IncludeAllWorkbooks' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Note that a Content Hub solution update can revert its own workbooks, so' -ForegroundColor Yellow
    Write-Host '  those may need scoping again after one.' -ForegroundColor Yellow
    Write-Host ''
}

$processedButBroken = @($broken | Where-Object { $_.Processed })
if ($processedButBroken.Count -gt 0) {
    Write-Host "$($processedButBroken.Count) workbook(s) were processed but are still not fully scoped:" -ForegroundColor Red
    foreach ($r in $processedButBroken) {
        Write-Host "    $($r.Name)  ($($r.Ok)/$($r.Total) queries)" -ForegroundColor Red
        foreach ($why in $r.Reasons) { Write-Host "        - $why" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host '  This is a tool defect rather than a configuration problem. Send this' -ForegroundColor Red
    Write-Host '  output on so the failing route can be fixed.' -ForegroundColor Red
    Write-Host ''
}

exit 3
