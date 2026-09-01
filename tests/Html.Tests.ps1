<#
    Tests for the self-contained HTML summary renderer.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Html.psm1') -Force -DisableNameChecking

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wbscope-html-tests-$([guid]::NewGuid().ToString('N'))"
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
            [switch]$OmitScopedViaPicker,
            [switch]$Minimal
        )

        if ($Minimal) {
            return [PSCustomObject]@{ DisplayName = $DisplayName; Action = $Action }
        }

        $props = [ordered]@{
            DisplayName       = $DisplayName
            WorkbookId        = 'workbook-id'
            Action            = $Action
            Eligible          = $Eligible
            Ineligible        = 0
            Added             = $Added
            Replaced          = $Replaced
            ParametersPatched = $ParametersPatched
            FallbackUpdated   = $false
            ParameterNames    = @()
            SnapshotPath      = ''
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

    function New-HtmlText {
        param([Parameter(Mandatory)][object]$RunResult, [switch]$NoDetailTables)

        $outDir = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        $path = New-ScopeSummaryHtml -RunResult $RunResult -OutputPath $outDir -NoDetailTables:$NoDetailTables
        return Get-Content -Path $path -Raw
    }
}

Describe 'HTML decommission readiness' {

    It 'says self-healing scoped workbooks keep working without a revert' {
        $html = New-HtmlText -RunResult (New-TestRunResult -ScopeMode SelfHealing -Results @(New-WorkbookResult)) -NoDetailTables

        $html | Should -Match 'The scoped workbooks will keep working when the source workspace is deleted; no revert is required first\.'
        $html | Should -Not -Match 'must be reverted first'
    }

    It 'says literal scoped workbooks must be reverted and shows the command' {
        $html = New-HtmlText -RunResult (New-TestRunResult -ScopeMode Literal -Results @(New-WorkbookResult)) -NoDetailTables

        $html | Should -Match 'The scoped workbooks will stop rendering when the source workspace is deleted and must be reverted first\.'
        $html | Should -Match 'Revert command: \.\\Sentinel-Workbook-Scope-Assistant\.ps1'
        $html | Should -Match '-Revert -Execute -Force'
    }

    It 'names failed workbooks when readiness is unknown' {
        $results = @(
            (New-WorkbookResult -DisplayName 'Good Workbook' -Action 'Scoped'),
            (New-WorkbookResult -DisplayName 'Broken Workbook' -Action 'Failed' -Reason 'PUT failed')
        )
        $html = New-HtmlText -RunResult (New-TestRunResult -Results $results) -NoDetailTables

        $html | Should -Match 'Decommission readiness is unknown for failed workbook\(s\): Broken Workbook\.'
        $html | Should -Not -Match 'will keep working when the source workspace is deleted'
    }

    It 'says a revert run is back to destination-only scope' {
        $html = New-HtmlText -RunResult (New-TestRunResult -Operation Revert -Results @(New-WorkbookResult -Action Reverted)) -NoDetailTables

        $html | Should -Match 'The workbooks are back to destination-only scope and the source workspace can be removed\.'
    }

    It 'does not claim readiness on an empty run' {
        $html = New-HtmlText -RunResult (New-TestRunResult -Results @()) -NoDetailTables

        $html | Should -Match 'No scoped workbook results were recorded, so decommission readiness cannot be determined from this run\.'
        $html | Should -Not -Match 'will keep working when the source workspace is deleted|source workspace can be removed'
    }
}

Describe 'HTML scope mode and statistics' {

    It 'renders the supplied scope mode' {
        $html = New-HtmlText -RunResult (New-TestRunResult -ScopeMode SelfHealing -Results @(New-WorkbookResult)) -NoDetailTables

        $html | Should -Match 'Scope mode: SelfHealing'
    }

    It 'treats an older run with no ScopeMode as literal' {
        { $script:OlderRunHtml = New-HtmlText -RunResult (New-TestRunResult -OmitScopeMode -Results @(New-WorkbookResult)) -NoDetailTables } | Should -Not -Throw

        $script:OlderRunHtml | Should -Match 'Scope mode: Literal'
        $script:OlderRunHtml | Should -Match '<div class="kpi-label">Scope mode</div>'
    }

    It 'does not render zero picker statistic cards' {
        $html = New-HtmlText -RunResult (New-TestRunResult -ScopeMode SelfHealing -Results @(New-WorkbookResult -ParametersPatched 0 -ScopedViaPicker 0)) -NoDetailTables

        $html | Should -Not -Match '<div class="kpi-label">Parameters patched</div>'
        $html | Should -Not -Match '<div class="kpi-label">Scoped via existing picker</div>'
    }

    It 'renders non-zero picker statistic cards with distinct labels' {
        $html = New-HtmlText -RunResult (New-TestRunResult -Results @(New-WorkbookResult -ParametersPatched 2 -ScopedViaPicker 3)) -NoDetailTables

        $html | Should -Match '<div class="kpi-value">2</div>\s*<div class="kpi-label">Parameters patched</div>'
        $html | Should -Match '<div class="kpi-value">3</div>\s*<div class="kpi-label">Scoped via existing picker</div>'
    }

    It 'treats a missing ScopedViaPicker field as zero' {
        $html = New-HtmlText -RunResult (New-TestRunResult -Results @(New-WorkbookResult -OmitScopedViaPicker -ParametersPatched 1)) -NoDetailTables

        $html | Should -Match '<div class="kpi-value">1</div>\s*<div class="kpi-label">Parameters patched</div>'
        $html | Should -Not -Match '<div class="kpi-label">Scoped via existing picker</div>'
    }
}

Describe 'HTML validation findings' {

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
        $html = New-HtmlText -RunResult (New-TestRunResult -ScopeMode SelfHealing -Results @(New-WorkbookResult) -Validation $validation)

        $html | Should -Match 'Scope parameter did not resolve\.'
        $html | Should -Match 'Resource Graph did not return ws-source'
        $html | Should -Match 'silently hides source data'
        $html | Should -Match '<td>Scope parameter</td>'
    }
}

Describe 'HTML encoding and self-contained output' {

    It 'encodes ampersands in workbook names' {
        $html = New-HtmlText -RunResult (New-TestRunResult -Results @(New-WorkbookResult -DisplayName 'SharePoint & OneDrive'))

        $html | Should -Match 'SharePoint &amp; OneDrive'
        $html | Should -Not -Match 'SharePoint & OneDrive'
    }

    It 'encodes markup and quotes in workbook names' {
        $html = New-HtmlText -RunResult (New-TestRunResult -Results @(New-WorkbookResult -DisplayName '<img src=x onerror="alert(1)"> "quoted"'))

        $html | Should -Match '&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt; &quot;quoted&quot;'
        $html | Should -Not -Match '<img\s+src=x'
        $html | Should -Not -Match 'onerror="alert\(1\)"'
    }

    It 'does not reference external HTTP assets or scripts' {
        $html = New-HtmlText -RunResult (New-TestRunResult -Results @(New-WorkbookResult))

        $html | Should -Not -Match 'https?://'
    }
}

Describe 'HTML renderer robustness' {

    It 'does not throw on sparse or broken diagnostic input' {
        $cases = @(
            (New-TestRunResult -Results @()),
            (New-TestRunResult -Results @(New-WorkbookResult) -Validation $null),
            (New-TestRunResult -Results @(New-WorkbookResult) -Preflight $null),
            (New-TestRunResult -Results @(New-WorkbookResult -Minimal)),
            (New-TestRunResult -Results @(New-WorkbookResult) -Duration 'not-a-timespan')
        )

        foreach ($case in $cases) {
            { $null = New-HtmlText -RunResult $case } | Should -Not -Throw
        }
    }

    It 'leaves no unexpanded PowerShell variables in customer-facing text' {
        $html = New-HtmlText -RunResult (New-TestRunResult -Results @(New-WorkbookResult))

        $html | Should -Not -Match '\$(sourceName|destName|scoped|reverted|RunResult)\b'
    }
}

AfterAll {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
