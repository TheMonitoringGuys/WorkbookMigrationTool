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

    Context 'Version 2 - full resource capture' {
        <#
            A PUT replaces the resource, so a snapshot holding only
            serializedData cannot restore what a run overwrote at resource
            level. Version 2 captures the resource as read.

            Version 1 files must keep working regardless: existing run folders
            are the customer's rollback source, and docs/recovery.md sends them
            there.
        #>

        BeforeAll {
            $script:Serialized = '{"version":"Notebook/1.0","items":[],"$schema":"https://example/workbook.json"}'
            $script:Resource = [PSCustomObject]@{
                name       = 'wb-v2'
                location   = 'eastus'
                kind       = 'shared'
                etag       = '"abc123"'
                identity   = [PSCustomObject]@{ type = 'UserAssigned' }
                tags       = [PSCustomObject]@{ MigratedFromWorkbookId = 'src-1'; 'hidden-title' = 'Lab' }
                properties = [PSCustomObject]@{
                    displayName    = 'Lab'
                    serializedData = $script:Serialized
                    category       = 'sentinel'
                }
            }
        }

        It 'captures the resource-level fields a content-only snapshot loses' {
            $out = Join-Path $script:TempDir 'snap-v2'
            $null = Save-WorkbookSnapshot -OutputPath $out -WorkbookId 'wb-v2' `
                -SerializedData $script:Serialized -Resource $script:Resource

            $res = Get-WorkbookSnapshot -OutputPath $out -WorkbookId 'wb-v2' -AsResource
            $res | Should -Not -BeNullOrEmpty
            $res.tags.MigratedFromWorkbookId | Should -Be 'src-1'
            $res.kind | Should -Be 'shared'
            $res.identity.type | Should -Be 'UserAssigned'
            $res.etag | Should -Be '"abc123"'
        }

        It 'still returns serializedData by default, so existing callers are unchanged' {
            $out = Join-Path $script:TempDir 'snap-v2-default'
            $null = Save-WorkbookSnapshot -OutputPath $out -WorkbookId 'wb-v2' `
                -SerializedData $script:Serialized -Resource $script:Resource

            Get-WorkbookSnapshot -OutputPath $out -WorkbookId 'wb-v2' | Should -BeExactly $script:Serialized
        }

        It 'reads a version 1 snapshot written by an earlier release' {
            # Written the way the previous version wrote it: the bare string.
            $out = Join-Path $script:TempDir 'snap-v1-compat'
            $dir = Join-Path $out 'snapshots'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            $script:Serialized | Set-Content -Path (Join-Path $dir 'legacy.json') -Encoding UTF8 -NoNewline

            Get-WorkbookSnapshot -OutputPath $out -WorkbookId 'legacy' | Should -BeExactly $script:Serialized
        }

        It 'reports no resource for a version 1 snapshot rather than inventing one' {
            $out = Join-Path $script:TempDir 'snap-v1-resource'
            $dir = Join-Path $out 'snapshots'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            $script:Serialized | Set-Content -Path (Join-Path $dir 'legacy2.json') -Encoding UTF8 -NoNewline

            Get-WorkbookSnapshot -OutputPath $out -WorkbookId 'legacy2' -AsResource | Should -BeNullOrEmpty
        }

        It 'survives a snapshot file that is not JSON at all' {
            $out = Join-Path $script:TempDir 'snap-garbage'
            $dir = Join-Path $out 'snapshots'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            'not json {' | Set-Content -Path (Join-Path $dir 'broken.json') -Encoding UTF8 -NoNewline

            Get-WorkbookSnapshot -OutputPath $out -WorkbookId 'broken' | Should -BeExactly 'not json {'
            Get-WorkbookSnapshot -OutputPath $out -WorkbookId 'broken' -AsResource | Should -BeNullOrEmpty
        }
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
