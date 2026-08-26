<#
    Tests for persisted export artifacts.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Export.psm1') -Force -DisableNameChecking

    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "wbscope-export-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    function New-RunResult {
        param(
            [object[]]$Results = @(),
            [object[]]$Errors = @(),
            [object]$Validation = $null
        )

        [PSCustomObject]@{
            Mode        = 'DryRun'
            Operation   = 'Apply'
            StartTime   = [datetime]'2026-01-01T00:00:00Z'
            EndTime     = [datetime]'2026-01-01T00:01:00Z'
            Duration    = [TimeSpan]::FromMinutes(1)
            ToolVersion = 'test'
            Source      = [PSCustomObject]@{ SubscriptionId = 'sub-a'; ResourceGroupName = 'rg-a'; WorkspaceName = 'ws-a' }
            Destination = [PSCustomObject]@{ SubscriptionId = 'sub-b'; ResourceGroupName = 'rg-b'; WorkspaceName = 'ws-b' }
            Preflight   = [PSCustomObject]@{ Passed = $true; CrossSubscription = $true; CrossRegion = $false }
            Results     = $Results
            Errors      = $Errors
            Validation  = $Validation
        }
    }
}

AfterAll {
    Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Workbook snapshots' {

    It 'creates the snapshots folder, writes serializedData verbatim, and returns the path' {
        $out = Join-Path $script:TempDir 'snapshot-write'
        $serialized = '{"title":"Résumé","items":[1,2,3]}'

        $path = Save-WorkbookSnapshot -OutputPath $out -WorkbookId 'sub/rg/wb:name' -SerializedData $serialized

        $path | Should -Be (Join-Path (Join-Path $out 'snapshots') 'sub_rg_wb_name.json')
        Test-Path (Join-Path $out 'snapshots') | Should -BeTrue
        [System.IO.File]::ReadAllBytes($path) | Should -Be ([System.Text.Encoding]::UTF8.GetBytes($serialized))
    }

    It 'round-trips a saved snapshot' {
        $out = Join-Path $script:TempDir 'snapshot-read'
        $serialized = '{"version":"Notebook/1.0","items":[]}'
        $null = Save-WorkbookSnapshot -OutputPath $out -WorkbookId 'wb1' -SerializedData $serialized

        Get-WorkbookSnapshot -OutputPath $out -WorkbookId 'wb1' | Should -BeExactly $serialized
    }

    It 'returns null for an unknown snapshot id' {
        Get-WorkbookSnapshot -OutputPath (Join-Path $script:TempDir 'missing') -WorkbookId 'unknown' | Should -BeNullOrEmpty
    }
}

Describe 'Raw JSON export' {

    It 'writes under the raw folder and produces re-parseable JSON' {
        $out = Join-Path $script:TempDir 'raw-json'
        $path = Save-RawJson -OutputPath $out -Name 'source/workbooks' -InputObject ([PSCustomObject]@{ name = 'wb'; count = 2 })

        $path | Should -Be (Join-Path (Join-Path $out 'raw') 'source-workbooks.json')
        $parsed = Get-Content $path -Raw | ConvertFrom-Json
        $parsed.name | Should -Be 'wb'
        $parsed.count | Should -Be 2
    }
}

Describe 'Scope result export' {

    It 'writes an XLSX when ImportExcel is available' -Skip:(-not (Get-Module -ListAvailable -Name ImportExcel)) {
        $out = Join-Path $script:TempDir 'xlsx'
        $path = Export-ScopeResult -RunResult (New-RunResult) -OutputPath $out -NoAutoInstall

        $path | Should -Be (Join-Path $out 'Scope-Results.xlsx')
        Test-Path $path | Should -BeTrue
    }

    It 'falls back to CSV when ImportExcel is unavailable' {
        Mock Test-ExportModuleAvailable -ModuleName WorkbookScope.Export { $false }
        $out = Join-Path $script:TempDir 'csv'

        $path = Export-ScopeResult -RunResult (New-RunResult) -OutputPath $out -NoAutoInstall

        $path | Should -Be (Join-Path $out 'csv')
        Test-Path (Join-Path $path 'Summary.csv') | Should -BeTrue
        Test-Path (Join-Path $path 'Workbooks.csv') | Should -BeTrue
        Test-Path (Join-Path $path 'Errors.csv') | Should -BeTrue
    }

    It 'does not throw for zero results, failures, or validation rows when writing CSV' {
        Mock Test-ExportModuleAvailable -ModuleName WorkbookScope.Export { $false }
        $run = New-RunResult `
            -Results @([PSCustomObject]@{ WorkbookId = 'wb1'; DisplayName = 'Workbook'; Action = 'Failed'; Method = ''; Eligible = 0; Ineligible = 0; Added = 0; Replaced = 0; ParametersPatched = 0; FallbackUpdated = $false; ParameterNames = @(); SnapshotPath = ''; Reason = 'bad' }) `
            -Errors @([PSCustomObject]@{ Component = 'Workbook'; Message = 'failed'; Remediation = 'retry'; Critical = $true }) `
            -Validation ([PSCustomObject]@{
                CrossQueryOk       = $false
                SourceTables       = @('SecurityEvent')
                DestinationTables  = @()
                OnlyInSource       = @('SecurityEvent')
                OnlyInDestination  = @()
                WorkbookFindings   = @([PSCustomObject]@{ DisplayName = 'Workbook'; MissingInDestination = @('SecurityEvent'); MissingInSource = @() })
                CrossQueryError    = 'query failed'
            })

        { Export-ScopeResult -RunResult (New-RunResult) -OutputPath (Join-Path $script:TempDir 'zero') -NoAutoInstall } | Should -Not -Throw
        { Export-ScopeResult -RunResult $run -OutputPath (Join-Path $script:TempDir 'failure') -NoAutoInstall } | Should -Not -Throw
        Test-Path (Join-Path (Join-Path (Join-Path $script:TempDir 'failure') 'csv') 'Validation.csv') | Should -BeTrue
    }
}
