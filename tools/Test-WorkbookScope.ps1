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

.PARAMETER ConfigFile
    The same config.yaml or config.json the scope tool uses. Both workspaces are
    read from it, so the audit examines exactly what a run would.

    Prefer this over typing the six values by hand. A mistyped source workspace is
    one of the faults this audit exists to find, and retyping it here is a good
    way to introduce a different one.

.EXAMPLE
    ./tools/Test-WorkbookScope.ps1 -ConfigFile ./config.yaml

.EXAMPLE
    ./tools/Test-WorkbookScope.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 `
        -ResourceGroupName my-rg -WorkspaceName new-workspace -SourceWorkspaceName old-workspace
#>
#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Config')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Config')]
    [string]$ConfigFile,

    [Parameter(Mandatory, ParameterSetName = 'Explicit')][string]$SubscriptionId,
    [Parameter(Mandatory, ParameterSetName = 'Explicit')][string]$ResourceGroupName,
    [Parameter(Mandatory, ParameterSetName = 'Explicit')][string]$WorkspaceName,
    [Parameter(Mandatory, ParameterSetName = 'Explicit')][string]$SourceWorkspaceName,
    [Parameter(ParameterSetName = 'Explicit')][string]$SourceSubscriptionId,
    [Parameter(ParameterSetName = 'Explicit')][string]$SourceResourceGroupName
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root 'src'

# Import-Module -Force removes a module before re-importing it, and every module
# here self-imports its own dependencies the same way. Loading Discovery unloads
# the Api and Engine copies this script already had. Re-importing the base
# modules at the tail, deepest-first, rebinds them into this scope - the same
# order the orchestrator uses, and for the same reason.
foreach ($m in @('Config', 'Discovery', 'Engine', 'Api', 'Common')) {
    Import-Module (Join-Path $srcDir "WorkbookScope.$m.psm1") -Force -DisableNameChecking
}

if ($PSCmdlet.ParameterSetName -eq 'Config') {
    if (-not (Test-Path $ConfigFile)) { throw "Config file not found: $ConfigFile" }
    $cfg = ConvertTo-NormalizedConfig -RawConfig (Read-ScopeConfig -Path $ConfigFile)

    $SubscriptionId = $cfg.Destination.SubscriptionId
    $ResourceGroupName = $cfg.Destination.ResourceGroupName
    $WorkspaceName = $cfg.Destination.WorkspaceName
    $SourceSubscriptionId = $cfg.Source.SubscriptionId
    $SourceResourceGroupName = $cfg.Source.ResourceGroupName
    $SourceWorkspaceName = $cfg.Source.WorkspaceName

    foreach ($pair in @(
            @{ N = 'destination.subscriptionId'; V = $SubscriptionId }
            @{ N = 'destination.resourceGroupName'; V = $ResourceGroupName }
            @{ N = 'destination.workspaceName'; V = $WorkspaceName }
            @{ N = 'source.subscriptionId'; V = $SourceSubscriptionId }
            @{ N = 'source.resourceGroupName'; V = $SourceResourceGroupName }
            @{ N = 'source.workspaceName'; V = $SourceWorkspaceName })) {
        if ([string]::IsNullOrWhiteSpace($pair.V)) { throw "Config file is missing $($pair.N)." }
    }
}

if (-not $SourceSubscriptionId) { $SourceSubscriptionId = $SubscriptionId }
if (-not $SourceResourceGroupName) { $SourceResourceGroupName = $ResourceGroupName }

$arm = Resolve-ArmEndpoint
$destId = Get-WorkspaceResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
$srcId = Get-WorkspaceResourceId -SubscriptionId $SourceSubscriptionId -ResourceGroupName $SourceResourceGroupName -WorkspaceName $SourceWorkspaceName

Write-Host ''
Write-Host 'Workbook scope audit' -ForegroundColor White
Write-Host ('-' * 100) -ForegroundColor DarkGray
# Print the fully resolved identities, not just the names. A source that names the
# wrong resource group or subscription is one of the faults this looks for, and it
# is invisible if only the workspace name is shown.
Write-Host "  destination : $WorkspaceName" -ForegroundColor White
Write-Host "                $destId" -ForegroundColor DarkGray
Write-Host "  source      : $SourceWorkspaceName" -ForegroundColor White
Write-Host "                $srcId" -ForegroundColor DarkGray
Write-Host ''

function Write-Check {
    param([string]$Label, [string]$Value, [ValidateSet('ok', 'bad', 'info')][string]$State = 'info')
    $mark = switch ($State) { 'ok' { '  OK  ' } 'bad' { ' FAIL ' } default { '      ' } }
    $colour = switch ($State) { 'ok' { 'Green' } 'bad' { 'Red' } default { 'Gray' } }
    Write-Host $mark -ForegroundColor $colour -NoNewline
    Write-Host ("{0,-15}" -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor Cyan
}

# ── Workspaces ────────────────────────────────────────────────────────────────
# The scope living in the JSON is only half the question. A workbook can name
# both workspaces perfectly and still show nothing from the old one, because
# what a query returns depends on things no amount of JSON inspection can see:
# whether the source workspace exists at the ID the run was given, whether this
# identity may read it, and whether it holds any data in the period on screen.
#
# Those are checked here, against the data plane, before the workbook table -
# because if the source cannot be read there is no point studying scope at all.
Write-Host 'Workspaces' -ForegroundColor White
Write-Host ('-' * 100) -ForegroundColor DarkGray

$laEndpoint = Resolve-LogAnalyticsEndpoint

function Get-WorkspaceFacts {
    param([string]$Sub, [string]$Rg, [string]$Name)
    try {
        $ws = Invoke-ScopeApi -Method GET -ThrottleDelayMs 50 -Uri (
            Get-WorkspaceUriWithVersion -WorkspaceUri (
                Get-ScopeWorkspaceUri -ArmEndpoint $arm -SubscriptionId $Sub -ResourceGroupName $Rg -WorkspaceName $Name))
        return [PSCustomObject]@{ Found = $true; CustomerId = [string]$ws.properties.customerId; Error = $null }
    }
    catch {
        return [PSCustomObject]@{ Found = $false; CustomerId = $null; Error = (Format-ApiErrorDetail -ErrorRecord $_) }
    }
}

function Get-WorkspaceData {
    param([string]$CustomerId)
    # Usage is cheap and answers both questions at once: how many streams have
    # arrived, and when the most recent one did.
    $q = 'Usage | where TimeGenerated > ago(90d) | summarize Tables=dcount(DataType), Latest=max(TimeGenerated)'
    try {
        $r = Invoke-ScopeApi -Method POST -ThrottleDelayMs 50 -ResourceUrl $laEndpoint `
            -Uri (Get-LogAnalyticsQueryUri -LogAnalyticsEndpoint $laEndpoint -WorkspaceId $CustomerId) `
            -Body @{ query = $q }
        $row = @($r.tables[0].rows)[0]
        return [PSCustomObject]@{ Ok = $true; Tables = $row[0]; Latest = $row[1]; Error = $null }
    }
    catch {
        return [PSCustomObject]@{ Ok = $false; Tables = 0; Latest = $null; Error = (Format-ApiErrorDetail -ErrorRecord $_) }
    }
}

$destWs = Get-WorkspaceFacts -Sub $SubscriptionId -Rg $ResourceGroupName -Name $WorkspaceName
$srcWs = Get-WorkspaceFacts -Sub $SourceSubscriptionId -Rg $SourceResourceGroupName -Name $SourceWorkspaceName

$sourceUsable = $true
foreach ($pair in @(
        @{ Label = 'destination'; Name = $WorkspaceName; Facts = $destWs }
        @{ Label = 'source'; Name = $SourceWorkspaceName; Facts = $srcWs })) {

    if (-not $pair.Facts.Found) {
        Write-Host ("  {0,-13} {1,-38} " -f $pair.Label, $pair.Name) -NoNewline
        Write-Host 'NOT REACHABLE' -ForegroundColor Red
        Write-Host "                $($pair.Facts.Error)" -ForegroundColor DarkGray
        if ($pair.Label -eq 'source') { $sourceUsable = $false }
        continue
    }

    $data = Get-WorkspaceData -CustomerId $pair.Facts.CustomerId
    if (-not $data.Ok) {
        # Failing to obtain a data-plane token is not the same as being unable to
        # read the workspace. The Log Analytics data plane is a different audience
        # from ARM and some tenants decline to issue it, which says nothing about
        # the workspace itself. Reporting that as "cannot read" would send someone
        # after a permissions problem that is not there.
        $tokenTrouble = $data.Error -match '(?i)credential|token|authentication failed|AADSTS'
        if ($tokenTrouble) {
            Write-Check $pair.Label "$($pair.Name)  -  reachable; data check unavailable" 'info'
            Write-Host "                could not get a Log Analytics token: $($data.Error)" -ForegroundColor DarkGray
            continue
        }

        Write-Host ("  {0,-13} {1,-38} " -f $pair.Label, $pair.Name) -NoNewline
        Write-Host 'CANNOT QUERY' -ForegroundColor Red
        Write-Host "                $($data.Error)" -ForegroundColor DarkGray
        if ($pair.Label -eq 'source') { $sourceUsable = $false }
        continue
    }

    $latest = if ($data.Latest) { ([datetime]$data.Latest).ToString('u') } else { 'never' }
    $state = if ([int]$data.Tables -gt 0) { 'ok' } else { 'bad' }
    Write-Check $pair.Label "$($pair.Name)  -  $($data.Tables) table(s), last data $latest" $state
    if ([int]$data.Tables -eq 0 -and $pair.Label -eq 'source') { $sourceUsable = $false }
}

# The probe that mirrors what a workbook actually does. Reading each workspace
# on its own can succeed while the union fails, because the data plane checks
# permission on every workspace named in the request.
if ($destWs.Found -and $srcWs.Found) {
    try {
        $null = Invoke-ScopeApi -Method POST -ThrottleDelayMs 50 -ResourceUrl $laEndpoint `
            -Uri (Get-LogAnalyticsQueryUri -LogAnalyticsEndpoint $laEndpoint -WorkspaceId $destWs.CustomerId) `
            -Body @{ query = 'print probe = 1'; workspaces = @($srcId) }
        Write-Check 'cross-workspace' 'both workspaces readable in one query' 'ok'
    }
    catch {
        Write-Check 'cross-workspace' 'FAILED' 'bad'
        Write-Host "                $(Format-ApiErrorDetail -ErrorRecord $_)" -ForegroundColor DarkGray
        Write-Host '                This is what a workbook does. If it fails here it will fail there,' -ForegroundColor Yellow
        Write-Host '                however the scope is written. Grant Log Analytics Reader on the' -ForegroundColor Yellow
        Write-Host '                source workspace to everyone who views these workbooks.' -ForegroundColor Yellow
        $sourceUsable = $false
    }
}

if (-not $sourceUsable) {
    Write-Host ''
    Write-Host '  The source workspace cannot be read, or holds no data. Until that is' -ForegroundColor Yellow
    Write-Host '  resolved the workbooks cannot show its data no matter how they are scoped,' -ForegroundColor Yellow
    Write-Host '  and re-running the scope tool will not change that.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Workbooks' -ForegroundColor White
Write-Host ('-' * 100) -ForegroundColor DarkGray

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
