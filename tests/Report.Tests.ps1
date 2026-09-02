<#
    Tests for the Markdown scope report renderer.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Report.psm1') -Force -DisableNameChecking

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wbscope-report-tests-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

    function New-WorkbookResult {
        param(
            [string]$DisplayName = 'Workbook A',
            [string]$Action = 'Scoped',
            [int]$Eligible = 2,
            [int]$Added = 2,
            [int]$Replaced = 0,
            [int]$ParametersPatched = 0,
            [Nullable[int]]$ScopedViaPicker = 0,
            [string]$Reason = '',
            [string]$Method = 'Manifest',
            [switch]$FallbackUpdated,
            [switch]$OmitScopedViaPicker,
            [switch]$Minimal
        )

        if ($Minimal) {
            return [PSCustomObject]@{ DisplayName = $DisplayName; Action = $Action }
        }

        $props = [ordered]@{
            DisplayName       = $DisplayName
            Action            = $Action
            Eligible          = $Eligible
            Added             = $Added
            Replaced          = $Replaced
            ParametersPatched = $ParametersPatched
            FallbackUpdated   = [bool]$FallbackUpdated
            Reason            = $Reason
            Method            = $Method
        }
        if (-not $OmitScopedViaPicker) { $props['ScopedViaPicker'] = [int]$ScopedViaPicker }
        return [PSCustomObject]$props
    }

    function New-TestRunResult {
        param(
            [string]$Mode = 'Execute',
            [string]$Operation = 'Scope',
            [string]$ScopeMode = 'SelfHealing',
            [object[]]$Results = @(),
            [object]$Validation = ([PSCustomObject]@{
                    CrossQueryOk           = $true
                    CrossQueryError        = $null
                    ScopeParameterResolves = $true
                    ScopeParameterError    = $null
                    SourceTables           = @()
                    DestinationTables      = @()
                    OnlyInSource           = @()
                    OnlyInDestination      = @()
                    WorkbookFindings       = @()
                }),
            [object]$Preflight = ([PSCustomObject]@{ Passed = $true; CrossSubscription = $false; CrossRegion = $false; Warnings = @(); Errors = @() }),
            [object[]]$Errors = @(),
            [object]$Duration = ([TimeSpan]::FromSeconds(90)),
            [switch]$OmitScopeMode
        )

        $run = [PSCustomObject][ordered]@{
            StartTime   = [datetime]'2026-08-31T20:00:00Z'
            EndTime     = [datetime]'2026-08-31T20:01:30Z'
            Duration    = $Duration
            Mode        = $Mode
            Operation   = $Operation
            ToolVersion = 'test'
            Source      = [PSCustomObject]@{
                SubscriptionId    = 'sub-src'
                ResourceGroupName = 'rg-src'
                WorkspaceName     = 'ws-source'
                ResourceId        = '/subscriptions/sub-src/resourceGroups/rg-src/providers/Microsoft.OperationalInsights/workspaces/ws-source'
                Location          = 'westus'
            }
            Destination = [PSCustomObject]@{
                SubscriptionId    = 'sub-dst'
                ResourceGroupName = 'rg-dst'
                WorkspaceName     = 'ws-dest'
                ResourceId        = '/subscriptions/sub-dst/resourceGroups/rg-dst/providers/Microsoft.OperationalInsights/workspaces/ws-dest'
                Location          = 'eastus'
            }
            Preflight   = $Preflight
            Results     = @($Results)
            Validation  = $Validation
            Errors      = @($Errors)
        }
        if (-not $OmitScopeMode) { $run | Add-Member -NotePropertyName ScopeMode -NotePropertyValue $ScopeMode }
        return $run
    }

    function New-ReportText {
        param([Parameter(Mandatory)][object]$RunResult)

        $outDir = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        $path = New-ScopeReport -RunResult $RunResult -OutputPath $outDir
        return Get-Content -Path $path -Raw
    }

    function Get-ReportSection {
        param([string]$Text, [string]$Start, [string]$End)

        $pattern = "(?s)## $([regex]::Escape($Start))\s*(.*?)## $([regex]::Escape($End))"
        $match = [regex]::Match($Text, $pattern)
        if (-not $match.Success) { return '' }
        return $match.Groups[1].Value
    }
}

Describe 'Markdown decommission readiness' {

    It 'says self-healing scoped workbooks keep working without a revert' {
        $report = New-ReportText -RunResult (New-TestRunResult -ScopeMode SelfHealing -Results @(New-WorkbookResult))

        $report | Should -Match 'The scoped workbooks will keep working when the source workspace is deleted; no revert is required first\.'
        $report | Should -Not -Match 'must be reverted first'
    }

    It 'says literal scoped workbooks must be reverted and shows the command' {
        $report = New-ReportText -RunResult (New-TestRunResult -ScopeMode Literal -Results @(New-WorkbookResult))

        $report | Should -Match 'The scoped workbooks will stop rendering when the source workspace is deleted and must be reverted first\.'
        $report | Should -Match 'Revert command: \.\\Sentinel-Workbook-Scope-Assistant\.ps1'
        $report | Should -Match '-Revert -Execute -Force'
    }

    It 'names failed workbooks when readiness is unknown' {
        $results = @(
            (New-WorkbookResult -DisplayName 'Good Workbook' -Action 'Scoped'),
            (New-WorkbookResult -DisplayName 'Broken Workbook' -Action 'Failed' -Reason 'PUT failed')
        )
        $report = New-ReportText -RunResult (New-TestRunResult -Results $results)

        $report | Should -Match 'Decommission readiness is unknown for failed workbook\(s\): Broken Workbook\.'
        $report | Should -Not -Match 'will keep working when the source workspace is deleted'
    }

    It 'says a revert run is back to destination-only scope' {
        $report = New-ReportText -RunResult (New-TestRunResult -Operation Revert -Results @(New-WorkbookResult -Action Reverted))

        $report | Should -Match 'The workbooks are back to destination-only scope and the source workspace can be removed\.'
    }

    It 'does not claim readiness on an empty run' {
        $report = New-ReportText -RunResult (New-TestRunResult -Results @())

        $report | Should -Match 'No scoped workbook results were recorded, so decommission readiness cannot be determined from this run\.'
        $report | Should -Not -Match 'will keep working when the source workspace is deleted|source workspace can be removed'
    }
}

Describe 'Markdown scope mode and statistics' {

    It 'renders the supplied scope mode' {
        $report = New-ReportText -RunResult (New-TestRunResult -ScopeMode SelfHealing -Results @(New-WorkbookResult))

        $report | Should -Match '\*\*Scope mode:\*\* SelfHealing'
    }

    It 'treats an older run with no ScopeMode as literal' {
        { $script:OlderRunReport = New-ReportText -RunResult (New-TestRunResult -OmitScopeMode -Results @(New-WorkbookResult)) } | Should -Not -Throw

        $script:OlderRunReport | Should -Match '\*\*Scope mode:\*\* Literal'
    }

    It 'does not put zero picker statistics in the KPI summary' {
        $report = New-ReportText -RunResult (New-TestRunResult -ScopeMode SelfHealing -Results @(New-WorkbookResult -ParametersPatched 0 -ScopedViaPicker 0))
        $kpis = Get-ReportSection -Text $report -Start 'KPI Summary' -End 'Decommission Readiness'

        $kpis | Should -Not -Match '\| Parameters patched\s*\|'
        $kpis | Should -Not -Match '\| Scoped via existing picker\s*\|'
    }

    It 'puts non-zero picker statistics in the KPI summary with distinct labels' {
        $report = New-ReportText -RunResult (New-TestRunResult -Results @(New-WorkbookResult -ParametersPatched 2 -ScopedViaPicker 3))
        $kpis = Get-ReportSection -Text $report -Start 'KPI Summary' -End 'Decommission Readiness'

        $kpis | Should -Match '\| Parameters patched\s*\| 2\s*\|'
        $kpis | Should -Match '\| Scoped via existing picker\s*\| 3\s*\|'
    }

    It 'treats a missing ScopedViaPicker field as zero' {
        $report = New-ReportText -RunResult (New-TestRunResult -Results @(New-WorkbookResult -OmitScopedViaPicker -ParametersPatched 1))
        $kpis = Get-ReportSection -Text $report -Start 'KPI Summary' -End 'Decommission Readiness'

        $kpis | Should -Match '\| Parameters patched\s*\| 1\s*\|'
        $kpis | Should -Not -Match '\| Scoped via existing picker\s*\|'
    }
}

Describe 'Markdown validation findings' {

    It 'surfaces self-healing scope parameter failures prominently' {
        $validation = [PSCustomObject]@{
            CrossQueryOk           = $true
            CrossQueryError        = $null
            ScopeParameterResolves = $false
            ScopeParameterError    = 'Resource Graph did not return ws-source; viewers would see destination-only data.'
            SourceTables           = @()
            DestinationTables      = @()
            OnlyInSource           = @()
            OnlyInDestination      = @()
            WorkbookFindings       = @()
        }
        $report = New-ReportText -RunResult (New-TestRunResult -ScopeMode SelfHealing -Results @(New-WorkbookResult) -Validation $validation)

        $report | Should -Match 'Scope parameter did not resolve\.'
        $report | Should -Match 'Resource Graph did not return ws-source'
        $report | Should -Match 'silently hides source data'
        $report | Should -Match '\*\*Scope parameter error:\*\* Resource Graph did not return ws-source'
    }
}

Describe 'Markdown renderer robustness' {

    It 'does not throw on sparse or broken diagnostic input' {
        $cases = @(
            (New-TestRunResult -Results @()),
            (New-TestRunResult -Results @(New-WorkbookResult) -Validation $null),
            (New-TestRunResult -Results @(New-WorkbookResult) -Preflight $null),
            (New-TestRunResult -Results @(New-WorkbookResult -Minimal)),
            (New-TestRunResult -Results @(New-WorkbookResult) -Duration 'not-a-timespan')
        )

        foreach ($case in $cases) {
            { $null = New-ReportText -RunResult $case } | Should -Not -Throw
        }
    }

    It 'leaves no unexpanded PowerShell variables in customer-facing text' {
        $report = New-ReportText -RunResult (New-TestRunResult -Results @(New-WorkbookResult))

        $report | Should -Not -Match '\$(sourceName|destName|scoped|reverted|RunResult)\b'
    }
}

Describe 'Scope evidence' {
    <#
        'Scoped' covers routes of very different strength, and the report used to
        present them identically. A workbook whose queries each name the source
        is a different claim from one where only the workbook-level fallback was
        extended - the latter is overridden by any query carrying its own scope.

        Reporting them the same way is how a run looks completely clean while a
        workbook returns no historical data. This is the real 'all devices' case
        from the sample corpus: Action=Scoped with every counter at zero.
    #>

    It 'calls per-query scope the strongest evidence' {
        $r = New-WorkbookResult -Added 3 -Replaced 1
        (Get-ScopeEvidence -Result $r).Label | Should -Be 'Per-query'
        (Get-ScopeEvidence -Result $r).Tone | Should -Be 'good'
    }

    It 'recognises a patched picker' {
        $r = New-WorkbookResult -Added 0 -Replaced 0 -ParametersPatched 2
        (Get-ScopeEvidence -Result $r).Label | Should -Be 'Picker'
        (Get-ScopeEvidence -Result $r).Tone | Should -Be 'good'
    }

    It 'recognises the injected reference appended beside a customer picker' {
        $r = New-WorkbookResult -Added 0 -Replaced 0 -ScopedViaPicker 4
        (Get-ScopeEvidence -Result $r).Label | Should -Be 'Picker'
    }

    It 'warns when only the workbook-level fallback was extended' {
        $r = New-WorkbookResult -Added 0 -Replaced 0 -ParametersPatched 0 -ScopedViaPicker 0 -FallbackUpdated
        (Get-ScopeEvidence -Result $r).Label | Should -Be 'Fallback only'
        (Get-ScopeEvidence -Result $r).Tone | Should -Be 'warn'
    }

    It 'reports no evidence when nothing changed at all' {
        $r = New-WorkbookResult -Added 0 -Replaced 0 -ParametersPatched 0 -ScopedViaPicker 0
        (Get-ScopeEvidence -Result $r).Label | Should -Be 'None'
        (Get-ScopeEvidence -Result $r).Tone | Should -Be 'bad'
    }

    It 'names weakly scoped workbooks in the report, not just a count' {
        # "3 workbooks on weak evidence" is not actionable in the report someone
        # reads when the dashboards disagree with the run.
        $run = New-TestRunResult -Results @(
            (New-WorkbookResult -DisplayName 'Strong wb' -Added 5),
            (New-WorkbookResult -DisplayName 'all devices' -Added 0 -Replaced 0 -ParametersPatched 0 -ScopedViaPicker 0 -FallbackUpdated)
        )
        $report = New-ReportText -RunResult $run

        $report | Should -Match 'Workbooks scoped on weak evidence'
        $report | Should -Match 'all devices'
        $report | Should -Match 'Fallback only'
    }

    It 'keeps the weak-evidence KPI off a report where every workbook is strongly scoped' {
        $run = New-TestRunResult -Results @((New-WorkbookResult -DisplayName 'Strong wb' -Added 5))
        $report = New-ReportText -RunResult $run

        $report | Should -Not -Match 'Scoped on weak evidence'
        $report | Should -Not -Match 'Workbooks scoped on weak evidence'
    }

    It 'does not label a failed workbook with scope evidence' {
        $run = New-TestRunResult -Results @(
            (New-WorkbookResult -DisplayName 'Broken wb' -Action 'Failed' -Added 0 -Replaced 0 -Reason 'boom')
        )
        $report = New-ReportText -RunResult $run

        $report | Should -Not -Match 'Workbooks scoped on weak evidence'
    }
}

AfterAll {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
