#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Sentinel Workbook Scope Assistant - point migrated workbooks at both the
    source and destination workspaces so one dashboard shows all the data.

.DESCRIPTION
    After the Sentinel Migration Assistant copies workbooks into a new workspace,
    those workbooks read only the new workspace. History left behind in the old
    one is invisible until its retention finally expires.

    This tool re-scopes those workbooks to read from both. It sets the
    'crossComponentResources' list that the Workbooks engine already unions
    across, and re-points any workspace picker parameter at both workspaces.
    No KQL is ever rewritten, and properties.sourceId is never touched, so the
    workbook stays exactly where it is in the destination Sentinel blade.

    Dual scope is transitional. When the source workspace is decommissioned, run
    -Revert to put the workbooks back to destination-only.

.PARAMETER ConfigFile
    Path to a YAML or JSON configuration file. See samples/config.yaml. A config
    file written for the Sentinel Migration Assistant works here unchanged - its
    'target' section is read as this tool's 'destination'.

.PARAMETER SourceSubscriptionId
    Subscription of the workspace migrated away from.

.PARAMETER SourceResourceGroup
    Resource group of the source workspace.

.PARAMETER SourceWorkspace
    Name of the source workspace - the one holding the older data.

.PARAMETER DestinationSubscriptionId
    Subscription of the workspace migrated to.

.PARAMETER DestinationResourceGroup
    Resource group of the destination workspace.

.PARAMETER DestinationWorkspace
    Name of the destination workspace, where the workbooks live now.

.PARAMETER DryRun
    Report what would change and write nothing. This is the default.

.PARAMETER Execute
    Apply the changes. Prompts for confirmation unless -Force is passed.

.PARAMETER Revert
    Restore destination-only scope. Combine with -Execute to apply it. Use this
    when the source workspace is being decommissioned.

.PARAMETER Cloud
    Azure cloud environment: Commercial or Gov.

.PARAMETER Force
    Skip the confirmation prompt in -Execute mode. Required for unattended runs.

.PARAMETER ValidateQueries
    After scoping, probe both workspaces to confirm the queries will actually
    resolve: run one real cross-workspace query, and compare which tables hold
    data in each. Opt-in because it needs Log Analytics data-plane read access,
    which is a separate grant from the ARM permissions this tool otherwise needs.

.PARAMETER LookbackDays
    Lookback window for the -ValidateQueries table inventory (default 7).

.PARAMETER WorkbookFilter
    Wildcard pattern matched against workbook display names, e.g. 'Azure*'.

.PARAMETER IncludeAllWorkbooks
    Act on every Sentinel workbook in the destination resource group, not only
    those the migration created. Widens the blast radius to workbooks this tool
    did not put there - including Content Hub ones, which a later solution
    update can silently revert.

.PARAMETER SnapshotPath
    Directory of a previous run whose snapshots -Revert should restore from.
    Without it, revert uses the manifest embedded in each workbook.

.PARAMETER RetryCount
    Retries on throttled or transient API errors (0-10, default 3).

.PARAMETER ThrottleMs
    Delay between API calls in milliseconds (default 100).

.PARAMETER SkipPreflight
    Bypass the workspace reachability and permission checks. Not recommended.

.PARAMETER NoDetailTables
    Build a slim HTML summary without the embedded per-workbook tables.

.PARAMETER NoAutoInstall
    Never install a missing PowerShell module. YAML config then stops with
    instructions, and the results export falls back to CSV.

.PARAMETER OutputDir
    Directory for reports, snapshots, and logs. Defaults to ./output. Each run
    writes a timestamped subfolder.

.EXAMPLE
    ./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -DryRun

    See what would change. Writes nothing.

.EXAMPLE
    ./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute -ValidateQueries

    Apply dual scope and prove the result actually renders.

.EXAMPLE
    ./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -Execute

    The source workspace is being decommissioned - put the workbooks back.

.NOTES
    Exit codes: 0 clean, 1 completed with failures, 2 could not start.

    Everyone who VIEWS these workbooks needs Log Analytics Reader on BOTH
    workspaces. Without it on the source, the workbook updates successfully and
    then renders empty.
#>
[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [string]$ConfigFile,

    [string]$SourceSubscriptionId,
    [string]$SourceResourceGroup,
    [string]$SourceWorkspace,

    [string]$DestinationSubscriptionId,
    [string]$DestinationResourceGroup,
    [string]$DestinationWorkspace,

    [Parameter(ParameterSetName = 'DryRun')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Execute')]
    [switch]$Execute,

    [switch]$Revert,

    [ValidateSet('Commercial', 'Gov')]
    [string]$Cloud,

    [Parameter(ParameterSetName = 'Execute')]
    [switch]$Force,

    [switch]$ValidateQueries,

    [ValidateRange(1, 365)]
    [int]$LookbackDays = -1,

    [string]$WorkbookFilter,
    [switch]$IncludeAllWorkbooks,
    [string]$SnapshotPath,

    [ValidateRange(0, 10)]
    [int]$RetryCount = -1,

    [ValidateRange(0, 60000)]
    [int]$ThrottleMs = -1,

    [switch]$SkipPreflight,
    [switch]$NoDetailTables,
    [switch]$NoAutoInstall,

    [string]$OutputDir = './output'
)

$ErrorActionPreference = 'Stop'
$script:ToolVersion = '1.0.0'

# ── Module loading ────────────────────────────────────────────────────────────
# Import-Module -Force removes a module before re-importing it, and every module
# here self-imports its own dependencies the same way. So loading Discovery -
# which imports Common and Api with -Force - unloads the copies the orchestrator
# already had and rebinds them into Discovery's private scope. The orchestrator
# is then left unable to call the very functions it loaded first.
#
# The fix is to re-import the base modules after the dependent ones, so the last
# word on Common, Api, and Engine belongs to this script. ModuleLoadOrder.Tests
# parses this list out of the file and fails if that trailing re-import is lost.
$srcDir = Join-Path $PSScriptRoot 'src'
$moduleLoadOrder = @(
    'Common', 'Api', 'Config', 'Engine',
    'Discovery', 'Preflight', 'Validate', 'Export', 'Report', 'Html',
    # Re-imported last, deliberately, deepest dependency first so that the
    # shallowest module has the final word. Engine and Api both self-import
    # Common, so Common must come after both. Do not reorder.
    'Engine', 'Api', 'Common'
)
foreach ($module in $moduleLoadOrder) {
    Import-Module (Join-Path $srcDir "WorkbookScope.$module.psm1") -Force -DisableNameChecking
}

# ── Console helpers ───────────────────────────────────────────────────────────
function Write-Banner {
    param([string]$Text)
    Write-Host ''
    Write-Host ('─' * 74) -ForegroundColor DarkGray
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('─' * 74) -ForegroundColor DarkGray
}

function Write-Step { param([string]$Text) Write-Host "`n$Text" -ForegroundColor White }

# ── Main ──────────────────────────────────────────────────────────────────────
$startTime = Get-Date
$errors = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()

try {
    Write-Banner "Sentinel Workbook Scope Assistant v$script:ToolVersion"

    # ── Configuration ─────────────────────────────────────────────────────────
    $config = $null
    if ($ConfigFile) {
        Write-Step 'Loading configuration...'
        $config = Read-ScopeConfig -Path $ConfigFile -NoAutoInstall:$NoAutoInstall
        Write-Host "  Loaded $ConfigFile" -ForegroundColor DarkGray
    }
    else {
        $config = ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{})
    }

    # -DryRun and -Execute are mutually exclusive parameter sets, so only an
    # explicit -Execute may turn writing on. Anything else stays a dry run,
    # including a config file that says dryRun: false but was invoked without it.
    # Build overrides from bound parameters only. An unbound [string] parameter
    # is an empty string rather than $null, so passing the whole set unfiltered
    # would overwrite every value just read from the config file with ''. That
    # failed loudly on options.cloud and silently on everything else.
    $overrides = @{}
    $paramToConfigKey = @{
        SourceSubscriptionId      = 'SourceSubscriptionId'
        SourceResourceGroup       = 'SourceResourceGroup'
        SourceWorkspace           = 'SourceWorkspace'
        DestinationSubscriptionId = 'DestinationSubscriptionId'
        DestinationResourceGroup  = 'DestinationResourceGroup'
        DestinationWorkspace      = 'DestinationWorkspace'
        Cloud                     = 'Cloud'
        WorkbookFilter            = 'WorkbookFilter'
        Revert                    = 'Revert'
        ValidateQueries           = 'ValidateQueries'
        IncludeAllWorkbooks       = 'IncludeAllWorkbooks'
    }
    foreach ($name in $paramToConfigKey.Keys) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $overrides[$paramToConfigKey[$name]] = $PSBoundParameters[$name]
        }
    }
    # These carry a sentinel default instead of a switch, so bind on value.
    if ($RetryCount -ge 0) { $overrides['RetryCount'] = $RetryCount }
    if ($ThrottleMs -ge 0) { $overrides['ThrottleMs'] = $ThrottleMs }
    if ($LookbackDays -ge 1) { $overrides['LookbackDays'] = $LookbackDays }

    $config = Merge-ParameterOverrides -Config $config -Overrides $overrides
    $config.Options.DryRun = -not $Execute
    Assert-ConfigValid -Config $config

    $isRevert = [bool]$config.Options.Revert
    $isDryRun = [bool]$config.Options.DryRun
    $operation = if ($isRevert) { 'Revert' } else { 'Scope' }
    $mode = if ($isDryRun) { 'DryRun' } else { 'Execute' }
    $throttle = [int]$config.Options.ThrottleMs

    Set-ScopeApiDefault -RetryCount ([int]$config.Options.RetryCount)

    # ── Prerequisites ─────────────────────────────────────────────────────────
    Write-Step 'Checking prerequisites...'
    Assert-ScopePrerequisite
    $armEndpoint = Resolve-ArmEndpoint -Cloud $config.Options.Cloud
    Write-Host "  ARM endpoint: $armEndpoint" -ForegroundColor DarkGray

    $sourceId = Get-WorkspaceResourceId -SubscriptionId $config.Source.SubscriptionId `
        -ResourceGroupName $config.Source.ResourceGroupName -WorkspaceName $config.Source.WorkspaceName
    $destId = Get-WorkspaceResourceId -SubscriptionId $config.Destination.SubscriptionId `
        -ResourceGroupName $config.Destination.ResourceGroupName -WorkspaceName $config.Destination.WorkspaceName

    Write-Host ''
    Write-Host "  Operation:    $operation ($mode)" -ForegroundColor $(if ($isDryRun) { 'Yellow' } else { 'Green' })
    Write-Host "  Source:       $($config.Source.WorkspaceName)" -ForegroundColor White
    Write-Host "  Destination:  $($config.Destination.WorkspaceName)" -ForegroundColor White

    # ── Preflight ─────────────────────────────────────────────────────────────
    $preflight = $null
    if ($SkipPreflight) {
        Write-Step 'Preflight skipped (-SkipPreflight).'
        $preflight = [PSCustomObject]@{
            Passed = $true; Warnings = @('Preflight checks were skipped.'); Errors = @()
            CrossSubscription = ($config.Source.SubscriptionId -ine $config.Destination.SubscriptionId)
            CrossRegion = $false; Source = $null; Destination = $null
        }
    }
    else {
        Write-Step 'Running preflight checks...'
        $preflight = Invoke-ScopePreflight -ArmEndpoint $armEndpoint `
            -SourceConfig $config.Source -DestinationConfig $config.Destination -ThrottleDelayMs $throttle

        foreach ($w in @(ConvertTo-SafeArray $preflight.Warnings)) {
            Write-Host "  ! $w" -ForegroundColor Yellow
        }
        foreach ($e in @(ConvertTo-SafeArray $preflight.Errors)) {
            Write-Host "  x $e" -ForegroundColor Red
        }
        if (-not $preflight.Passed) {
            throw "Preflight failed. Resolve the errors above, or pass -SkipPreflight to bypass these checks."
        }
    }

    # ── Discovery ─────────────────────────────────────────────────────────────
    Write-Step 'Discovering workbooks in the destination...'
    $workbooks = @(Get-DestinationWorkbook -ArmEndpoint $armEndpoint `
            -SubscriptionId $config.Destination.SubscriptionId `
            -ResourceGroupName $config.Destination.ResourceGroupName `
            -WorkspaceResourceId $destId `
            -WorkbookFilter $config.Options.WorkbookFilter `
            -IncludeAllWorkbooks:$config.Options.IncludeAllWorkbooks `
            -ThrottleDelayMs $throttle)

    if ($workbooks.Count -eq 0) {
        Write-Host ''
        Write-Host '  No workbooks matched.' -ForegroundColor Yellow
        Write-Host '  By default only workbooks tagged MigratedFromWorkbookId are considered -' -ForegroundColor DarkGray
        Write-Host '  those the Sentinel Migration Assistant created. Pass -IncludeAllWorkbooks' -ForegroundColor DarkGray
        Write-Host '  to widen the search, or check -WorkbookFilter.' -ForegroundColor DarkGray
    }

    # ── Output folder ─────────────────────────────────────────────────────────
    $stamp = $startTime.ToString('yyyyMMdd-HHmmss')
    $runName = "scope-$($config.Source.WorkspaceName)-with-$($config.Destination.WorkspaceName)-$stamp"
    $runName = $runName -replace '[^\w\-\.]', '-'
    $outputPath = Join-Path $OutputDir $runName
    New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

    # ── Confirmation ──────────────────────────────────────────────────────────
    if (-not $isDryRun -and -not $Force -and $workbooks.Count -gt 0) {
        Write-Host ''
        Write-Host '  About to modify workbooks in:' -ForegroundColor Yellow
        Write-Host "    $($config.Destination.WorkspaceName)  ($($config.Destination.ResourceGroupName))" -ForegroundColor White
        Write-Host "  Workbooks affected: $($workbooks.Count)" -ForegroundColor White
        if ($isRevert) {
            Write-Host '  They will be reverted to reading the destination workspace only.' -ForegroundColor White
        }
        else {
            Write-Host "  They will additionally read: $($config.Source.WorkspaceName)" -ForegroundColor White
        }
        Write-Host ''
        $answer = Read-Host '  Continue? [y/N]'
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            exit 0
        }
    }

    # ── Process ───────────────────────────────────────────────────────────────
    if ($workbooks.Count -gt 0) {
        $verb = if ($isRevert) { 'Reverting' } else { 'Scoping' }
        Write-Step "$verb $($workbooks.Count) workbook(s)..."
    }

    $current = 0
    foreach ($wb in $workbooks) {
        $current++
        $displayName = Get-WorkbookDisplayName -Workbook $wb
        Write-ScopeProgress -Activity "$operation workbooks" -Status $displayName -Current $current -Total $workbooks.Count
        Write-Host ("    [{0}/{1}] {2}" -f $current, $workbooks.Count, $displayName) -ForegroundColor White -NoNewline

        $result = [PSCustomObject]@{
            WorkbookId = $wb.name; DisplayName = $displayName; Action = 'Failed'; Method = $null
            Eligible = 0; Ineligible = 0; Added = 0; Replaced = 0; ParametersPatched = 0
            FallbackUpdated = 0; ParameterNames = @(); SnapshotPath = $null; Reason = $null
            Tables = @()
        }

        try {
            $serialized = [string]$wb.properties.serializedData
            if ([string]::IsNullOrWhiteSpace($serialized)) {
                throw 'Workbook has no serializedData to modify.'
            }

            # Snapshot before the first edit - this is the authoritative restore
            # source, so it must exist even if everything after this point fails.
            $result.SnapshotPath = Save-WorkbookSnapshot -OutputPath $outputPath `
                -WorkbookId $wb.name -SerializedData $serialized

            $root = ConvertFrom-SerializedWorkbook -Json $serialized
            $summary = Get-WorkbookScopeSummary -Root $root
            $result.Eligible = $summary.Eligible
            $result.Ineligible = $summary.Ineligible
            $result.ParameterNames = @($summary.ParameterNames)

            if ($isRevert) {
                # A snapshot from the run that applied the scope beats the
                # embedded manifest: it is the exact original, not a replay.
                $restored = $null
                if ($SnapshotPath) {
                    $restored = Get-WorkbookSnapshot -OutputPath $SnapshotPath -WorkbookId $wb.name
                }
                if ($restored) {
                    $newSerialized = $restored
                    $result.Action = 'Reverted'
                    $result.Method = 'Snapshot'
                }
                else {
                    $rev = Restore-WorkbookScope -Root $root -SourceWorkspaceId $sourceId
                    $result.Action = $rev.Action
                    $result.Method = $rev.Method
                    $newSerialized = ConvertTo-SerializedWorkbook -Root $root
                }
            }
            else {
                $applied = Set-WorkbookDualScope -Root $root `
                    -SourceWorkspaceId $sourceId -DestinationWorkspaceId $destId `
                    -SourceSubscriptionId $config.Source.SubscriptionId `
                    -DestinationSubscriptionId $config.Destination.SubscriptionId

                $result.Action = $applied.Action
                $result.Added = $applied.Stats.Added
                $result.Replaced = $applied.Stats.Replaced
                $result.ParametersPatched = $applied.Stats.ParametersPatched
                $result.FallbackUpdated = $applied.Stats.Fallback
                $newSerialized = ConvertTo-SerializedWorkbook -Root $root
                $result.Tables = @(Get-WorkbookQueryTable -Root $root)
            }

            # Nothing changed - do not spend an ARM write, and do not restamp the
            # tag, so a re-run leaves the workbook's timestamp meaningful.
            if ($result.Action -in @('AlreadyScoped', 'NotScoped')) {
                Write-Host " -> $(Format-ActionLabel $result.Action)" -ForegroundColor (Get-ActionColor $result.Action)
                $results.Add($result)
                continue
            }

            $tags = Get-WorkbookScopeTag -ExistingTags $wb.tags `
                -SourceWorkspaceName $config.Source.WorkspaceName -Revert:$isRevert

            $props = $wb.properties | ConvertTo-Json -Depth 100 | ConvertFrom-Json
            $props.serializedData = $newSerialized
            # Read-only on the workbooks API; sending them back is rejected.
            foreach ($ro in @('timeModified', 'userId', 'revision')) {
                if ($props.PSObject.Properties[$ro]) { $props.PSObject.Properties.Remove($ro) }
            }

            $body = @{
                location   = $wb.location
                tags       = $tags
                kind       = if ($wb.kind) { $wb.kind } else { 'shared' }
                properties = $props
            }

            $uri = Get-WorkbookUri -ArmEndpoint $armEndpoint `
                -SubscriptionId $config.Destination.SubscriptionId `
                -ResourceGroupName $config.Destination.ResourceGroupName `
                -WorkbookId $wb.name

            $null = Invoke-ScopeApi -Uri $uri -Method PUT -Body $body -DryRun:$isDryRun -ThrottleDelayMs $throttle

            if ($isDryRun) { $result.Action = "WouldBe$($result.Action)" }
        }
        catch {
            $result.Action = 'Failed'
            $result.Reason = Format-ApiErrorDetail -ErrorRecord $_
            $errors.Add([PSCustomObject]@{
                    Component = "Workbook: $displayName"
                    Message = $result.Reason
                    Remediation = 'Re-run to retry. If it persists, check Microsoft Sentinel Contributor on the destination resource group.'
                    Critical = $false
                })
        }

        Write-Host " -> $(Format-ActionLabel $result.Action)" -ForegroundColor (Get-ActionColor $result.Action)
        if ($result.Reason -and (Get-NormalizedAction $result.Action) -eq 'Failed') {
            Write-Host "      $($result.Reason)" -ForegroundColor Red
        }
        $results.Add($result)
    }
    Write-ScopeProgress -Activity "$operation workbooks" -Completed

    # ── Validation ────────────────────────────────────────────────────────────
    $validation = $null
    if ($config.Options.ValidateQueries -and -not $isRevert) {
        Write-Step 'Validating queries...'
        if ($SkipPreflight -or -not $preflight.Source -or -not $preflight.Destination) {
            Write-Warning 'Validation needs the workspace GUIDs that preflight resolves. Skipped.'
        }
        else {
            $validation = Invoke-SafeCollection -Name 'Validation' -ErrorSink $errors `
                -Remediation 'Validation is diagnostic only; the workbooks were still updated.' -Action {
                Invoke-ScopeValidation `
                    -LogAnalyticsEndpoint (Resolve-LogAnalyticsEndpoint) `
                    -SourceCustomerId $preflight.Source.CustomerId `
                    -DestinationCustomerId $preflight.Destination.CustomerId `
                    -SourceWorkspaceResourceId $sourceId `
                    -Workbooks $results.ToArray() `
                    -LookbackDays ([int]$config.Options.LookbackDays) `
                    -ThrottleDelayMs $throttle
            } | Select-Object -First 1
        }
    }

    # ── Artifacts ─────────────────────────────────────────────────────────────
    $endTime = Get-Date
    $runResult = [PSCustomObject]@{
        StartTime = $startTime; EndTime = $endTime; Duration = ($endTime - $startTime)
        Mode = $mode; Operation = $operation; ToolVersion = $script:ToolVersion
        Source = [PSCustomObject]@{
            SubscriptionId = $config.Source.SubscriptionId
            ResourceGroupName = $config.Source.ResourceGroupName
            WorkspaceName = $config.Source.WorkspaceName
            ResourceId = $sourceId
            Location = $(if ($preflight.Source) { $preflight.Source.Location } else { $null })
        }
        Destination = [PSCustomObject]@{
            SubscriptionId = $config.Destination.SubscriptionId
            ResourceGroupName = $config.Destination.ResourceGroupName
            WorkspaceName = $config.Destination.WorkspaceName
            ResourceId = $destId
            Location = $(if ($preflight.Destination) { $preflight.Destination.Location } else { $null })
        }
        Preflight = $preflight
        Results = @($results.ToArray())
        Validation = $validation
        Errors = @($errors.ToArray())
        OutputPath = $outputPath
    }

    Write-Step 'Writing reports...'
    $null = Invoke-SafeCollection -Name 'Raw JSON' -ErrorSink $errors -Action {
        Save-RawJson -OutputPath $outputPath -Name 'RunResult' -InputObject $runResult
    }
    $null = Invoke-SafeCollection -Name 'Markdown report' -ErrorSink $errors -Action {
        New-ScopeReport -RunResult $runResult -OutputPath $outputPath
    }
    $null = Invoke-SafeCollection -Name 'HTML summary' -ErrorSink $errors -Action {
        New-ScopeSummaryHtml -RunResult $runResult -OutputPath $outputPath -NoDetailTables:$NoDetailTables
    }
    $null = Invoke-SafeCollection -Name 'Results export' -ErrorSink $errors -Action {
        Export-ScopeResult -RunResult $runResult -OutputPath $outputPath -NoAutoInstall:$NoAutoInstall
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    $normalized = @($results | ForEach-Object { Get-NormalizedAction $_.Action })
    $changed = @($normalized | Where-Object { $_ -in @('Scoped', 'Reverted') }).Count
    $unchanged = @($normalized | Where-Object { $_ -in @('AlreadyScoped', 'NotScoped', 'Skipped') }).Count
    $failed = @($normalized | Where-Object { $_ -eq 'Failed' }).Count

    Write-Banner 'Summary'
    Write-Host "  Workbooks changed:   $changed" -ForegroundColor $(if ($changed) { 'Green' } else { 'DarkGray' })
    Write-Host "  Unchanged:           $unchanged" -ForegroundColor DarkGray
    Write-Host "  Failed:              $failed" -ForegroundColor $(if ($failed) { 'Red' } else { 'DarkGray' })
    Write-Host "  Duration:            $(Format-RunDuration ($endTime - $startTime))" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "  Output: $outputPath" -ForegroundColor Cyan
    Write-Host '  Open Scope-Summary.html for the next steps from this run.' -ForegroundColor DarkGray

    if ($isDryRun -and $changed -gt 0) {
        Write-Host ''
        Write-Host '  This was a dry run - nothing was changed.' -ForegroundColor Yellow
        Write-Host '  Re-run with -Execute to apply.' -ForegroundColor Yellow
    }
    Write-Host ''

    exit $(if ($failed -gt 0) { 1 } else { 0 })
}
catch {
    Write-Host ''
    Write-Host "  Could not complete: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Verbose $_.ScriptStackTrace
    exit 2
}
