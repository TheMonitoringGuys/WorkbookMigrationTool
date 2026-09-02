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

$listUri = Get-WorkbooksUri -ArmEndpoint $arm -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -SourceId $destId -ExcludeContent
$stubs = @(Invoke-ScopeApiList -Uri $listUri -ThrottleDelayMs 50)

Write-Host ("  {0,-44} {1,-8} {2,-9} {3,-12} {4}" -f 'WORKBOOK', 'MIGRATED', 'PROCESSED', 'QUERIES', 'VERDICT') -ForegroundColor DarkGray

$rows = [System.Collections.Generic.List[object]]::new()

$unreadable = 0

foreach ($stub in $stubs) {
    if (-not $stub.id) { continue }
    $wbId = ($stub.id -split '/')[-1]
    try {
        $wb = Invoke-ScopeApi -Method GET -ThrottleDelayMs 50 -Uri (
            Get-WorkbookUri -ArmEndpoint $arm -SubscriptionId $SubscriptionId `
                -ResourceGroupName $ResourceGroupName -WorkbookId $wbId -IncludeContent)
    }
    catch {
        $unreadable++
        Write-Warning "Could not read workbook '$wbId': $($_.Exception.Message)"
        continue
    }

    $name = Get-WorkbookDisplayName -Workbook $wb
    $migrated = Test-WorkbookIsMigrated -Workbook $wb

    # ConvertFrom-SerializedWorkbook throws on empty, whitespace or malformed
    # content, and a workbook with no content is ordinary - the portal will create
    # one. Uncaught, a single such workbook would end the audit part-way through
    # the table and produce no conclusions at all, which is precisely when this
    # tool is being relied on.
    try {
        $tree = ConvertFrom-SerializedWorkbook -Json ([string]$wb.properties.serializedData)
    }
    catch {
        $unreadable++
        $short = if ($name.Length -gt 42) { $name.Substring(0, 42) } else { $name }
        Write-Host ("  {0,-44} {1,-8} {2,-9} {3,-12} " -f $short, $(if ($migrated) { 'yes' } else { 'no' }), '-', '-') -NoNewline
        Write-Host 'UNREADABLE' -ForegroundColor Magenta
        continue
    }

    $processed = [bool](Get-DualScopeManifest -Root $tree)

    # One implementation of "is this actually scoped", shared with the engine, so
    # the audit and the tool that does the work can never disagree about it.
    $check = Test-WorkbookDualScoped -Root $tree -SourceWorkspaceId $srcId -DestinationWorkspaceId $destId
    $ok = $check.Satisfied
    $bad = $check.Unsatisfied
    $total = $check.Total
    $reasons = @($check.Reasons)

    $verdict = 'PARTIAL'
    if ($total -eq 0 -and -not $check.Scoped) { $verdict = 'no queries' }
    elseif ($check.Scoped) { $verdict = 'OK' }
    elseif ($ok -eq 0) { $verdict = 'NOT SCOPED' }

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
$taggedButUnrun = @($untouched | Where-Object { $_.Migrated })

# Every read failed, yet the listing proved workbooks exist. Saying "none found"
# here would assert the opposite of what was just observed and send someone
# looking for a subscription or workspace mismatch that is not there.
if ($rows.Count -eq 0 -and $unreadable -gt 0) {
    Write-Host "All $unreadable workbook(s) bound to this workspace could not be read, so none could be assessed." -ForegroundColor Red
    Write-Host 'They exist - the listing returned them - but fetching their content failed.' -ForegroundColor Red
    Write-Host 'Run tools/Test-ScopeConnection.ps1 to establish why.' -ForegroundColor Yellow
    exit 2
}

if ($rows.Count -eq 0) {
    Write-Host 'No workbooks found bound to that workspace.' -ForegroundColor Yellow
    exit 2
}

# Nothing had a query to assess, so there is nothing to certify either way.
if (@($rows | Where-Object { $_.Total -gt 0 }).Count -eq 0) {
    Write-Host 'None of these workbooks contain Log Analytics queries, so there is nothing to scope.' -ForegroundColor Yellow
    exit 0
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
    if ($unreadable -gt 0) {
        Write-Host ''
        Write-Warning "$unreadable workbook(s) could not be read and were not assessed."
        exit 3
    }
    exit 0
}

# The ordinary case: the Migration Assistant produced these, and the scope tool
# has not been run over them yet. Previously this matched no branch at all and the
# script exited non-zero having printed nothing after the table.
if ($taggedButUnrun.Count -gt 0) {
    Write-Host "$($taggedButUnrun.Count) migrated workbook(s) have not been scoped yet:" -ForegroundColor Yellow
    $taggedButUnrun | Select-Object -First 10 | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Yellow }
    if ($taggedButUnrun.Count -gt 10) { Write-Host "    ... and $($taggedButUnrun.Count - 10) more" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  These carry the migration tag, so a normal run will pick them up:' -ForegroundColor Green
    Write-Host '     ./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -DryRun' -ForegroundColor Green
    Write-Host '     ./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute' -ForegroundColor Green
    Write-Host ''
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
    Write-Host "$($processedButBroken.Count) workbook(s) carry a scope record but do not match it:" -ForegroundColor Red
    foreach ($r in $processedButBroken) {
        Write-Host "    $($r.Name)  ($($r.Ok)/$($r.Total) queries)" -ForegroundColor Red
        foreach ($why in $r.Reasons) { Write-Host "        - $why" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host '  A previous run scoped these and something has since undone it - usually a' -ForegroundColor Yellow
    Write-Host '  portal edit or a Content Hub solution refresh, both of which rewrite the' -ForegroundColor Yellow
    Write-Host '  workbook and can drop the scope while leaving the record behind.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Up to version 1.2.6 the tool trusted that record and reported these as' -ForegroundColor Yellow
    Write-Host '  already scoped, so re-running changed nothing. From 1.2.7 it checks the' -ForegroundColor Yellow
    Write-Host '  workbook itself and repairs them.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Upgrade, then re-run:' -ForegroundColor Green
    Write-Host '     ./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute' -ForegroundColor Green
    Write-Host ''
}

exit 3
