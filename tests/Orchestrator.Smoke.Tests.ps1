<#
    End-to-end smoke test for the orchestrator.

    Unit tests pass while the script that wires the units together is broken -
    the module load-order defect and the empty-string override both got through
    a green unit suite. These tests run the real entry point in a child process
    and assert on exit codes and the artifacts a customer actually receives.

    The network is stubbed at Invoke-RestMethod, one level below the tool's own
    API wrapper, so retry handling, URI construction, dry-run suppression and the
    whole module stack are exercised for real. Stubbing the wrapper itself would
    have hidden exactly the kind of wiring bug these tests exist to catch.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $script:RepoRoot 'Sentinel-Workbook-Scope-Assistant.ps1'
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\workbooks.json'

    function Invoke-Orchestrator {
        param([hashtable]$Parameters = @{}, [switch]$NoWorkbooks, [switch]$SourceDeleted)

        $work = Join-Path ([System.IO.Path]::GetTempPath()) "wbscope-smoke-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $work -Force | Out-Null

        $outDir = Join-Path $work 'output'
        $capture = Join-Path $work 'puts.jsonl'
        $stdout = Join-Path $work 'stdout.txt'
        $stderr = Join-Path $work 'stderr.txt'

        $configPath = Join-Path $work 'config.json'
        @{
            source      = @{ subscriptionId = '11111111-1111-1111-1111-111111111111'; resourceGroupName = 'rg-src'; workspaceName = 'ws-source' }
            destination = @{ subscriptionId = '22222222-2222-2222-2222-222222222222'; resourceGroupName = 'rg-dest'; workspaceName = 'ws-dest' }
            options     = @{ cloud = 'Commercial'; throttleMs = 0 }
        } | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8

        $paramLine = ($Parameters.GetEnumerator() | ForEach-Object {
                if ($_.Value -is [switch] -or $_.Value -is [bool]) {
                    if ($_.Value) { "-$($_.Key)" }
                }
                else { "-$($_.Key) '$([string]$_.Value -replace "'","''")'" }
            }) -join ' '

        $workbooksJson = if ($NoWorkbooks) { '@()' } else { "(Get-Content '$($script:Fixture -replace "'","''")' -Raw | ConvertFrom-Json)" }
        $sourceBranch = ''
        if ($SourceDeleted) {
            $sourceBranch = @"
    if (`$Uri -match '/workspaces/ws-source\?') {
        throw 'Response status code does not indicate success: 404 (Not Found).'
    }
"@
        }

        # Baked into a generated harness rather than passed as process arguments:
        # a command line containing quotes does not survive argument splitting.
        $harness = @"
`$ErrorActionPreference = 'Stop'

# Az surface the tool touches.
function Get-AzContext {
    [PSCustomObject]@{
        Account      = [PSCustomObject]@{ Id = 'smoke@example.com' }
        Subscription = [PSCustomObject]@{ Id = 'sub-1' }
        Tenant       = [PSCustomObject]@{ Id = 'tenant-1' }
        Environment  = [PSCustomObject]@{ Name = 'AzureCloud' }
    }
}
function Get-AzEnvironment {
    param([string]`$Name)
    [PSCustomObject]@{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/' }
}
function Get-AzAccessToken { param([string]`$ResourceUrl) [PSCustomObject]@{ Token = 'stub-token' } }

`$global:Workbooks = $workbooksJson

# The single network seam. Everything above it runs for real.
function global:Invoke-RestMethod {
    # CmdletBinding supplies -ErrorAction and friends. Declaring ErrorAction
    # explicitly collides with the automatic common parameter.
    [CmdletBinding()]
    param(`$Uri, `$Method = 'GET', `$Headers, `$Body)

    if (`$Method -eq 'PUT') {
        Add-Content -Path '$($capture -replace "'","''")' -Value (`$Uri) -Encoding UTF8
        return [PSCustomObject]@{ id = `$Uri; name = 'stub' }
    }
$sourceBranch
    # Workspace GET: existence, location, and the GUID validation needs.
    if (`$Uri -match '/workspaces/[^/?]+\?api-version') {
        return [PSCustomObject]@{
            id         = (`$Uri -split '\?')[0]
            location   = 'eastus'
            properties = [PSCustomObject]@{ customerId = '00000000-0000-0000-0000-0000000000ff' }
        }
    }

    # Workbook list.
    if (`$Uri -match '/workbooks\?') {
        return [PSCustomObject]@{ value = `$global:Workbooks }
    }

    return [PSCustomObject]@{ value = @() }
}

& '$($script:Script -replace "'","''")' -ConfigFile '$($configPath -replace "'","''")' -OutputDir '$($outDir -replace "'","''")' $paramLine
exit `$LASTEXITCODE
"@

        $harnessPath = Join-Path $work 'harness.ps1'
        Set-Content -Path $harnessPath -Value $harness -Encoding UTF8

        $p = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $harnessPath) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr

        $runDir = $null
        if (Test-Path $outDir) {
            $runDir = Get-ChildItem $outDir -Directory | Select-Object -First 1 -ExpandProperty FullName
        }

        [PSCustomObject]@{
            ExitCode = $p.ExitCode
            Stdout   = if (Test-Path $stdout) { Get-Content $stdout -Raw } else { '' }
            Stderr   = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { '' }
            Puts     = if (Test-Path $capture) { @(Get-Content $capture) } else { @() }
            RunDir   = $runDir
            WorkDir  = $work
        }
    }
}

Describe 'Orchestrator entry point' {

    It 'parses without syntax errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It 'makes -Execute a switch, so omitting it cannot silently enable writes' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
        $execute = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Execute' }
        $execute | Should -Not -BeNullOrEmpty
        $execute.StaticType.Name | Should -Be 'SwitchParameter'
    }
}

Describe 'Dry run' {

    BeforeAll { $script:Dry = Invoke-Orchestrator -Parameters @{ DryRun = $true; SkipPreflight = $true } }

    It 'exits zero' {
        $script:Dry.ExitCode | Should -Be 0 -Because "stdout was:`n$($script:Dry.Stdout)`n$($script:Dry.Stderr)"
    }

    It 'writes nothing to Azure' {
        # The whole promise of the default mode.
        @($script:Dry.Puts).Count | Should -Be 0
    }

    It 'still produces the reports a customer reviews' {
        $script:Dry.RunDir | Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $script:Dry.RunDir 'Scope-Summary.html') | Should -BeTrue
        Test-Path (Join-Path $script:Dry.RunDir 'scope-report.md') | Should -BeTrue
    }

    It 'snapshots every workbook before touching anything' {
        # The authoritative restore source, so it must exist even in a dry run.
        $snapshots = @(Get-ChildItem (Join-Path $script:Dry.RunDir 'snapshots') -Filter '*.json' -ErrorAction SilentlyContinue)
        $snapshots.Count | Should -Be 16
    }

    It 'says plainly that nothing was changed' {
        $script:Dry.Stdout | Should -Match '(?i)dry run'
    }
}

Describe 'Execute' {

    BeforeAll { $script:Run = Invoke-Orchestrator -Parameters @{ Execute = $true; Force = $true; SkipPreflight = $true } }

    It 'exits zero' {
        $script:Run.ExitCode | Should -Be 0 -Because "stdout was:`n$($script:Run.Stdout)`n$($script:Run.Stderr)"
    }

    It 'writes every workbook exactly once' {
        @($script:Run.Puts).Count | Should -Be 16
        @($script:Run.Puts | Sort-Object -Unique).Count | Should -Be 16
    }

    It 'writes only to the destination resource group' {
        # Source content is never modified. This is the assertion that would
        # catch a swapped source/destination.
        foreach ($uri in $script:Run.Puts) {
            $uri | Should -Match 'resourceGroups/rg-dest/'
            $uri | Should -Not -Match 'resourceGroups/rg-src/'
        }
    }

    It 'produces the full artifact set' {
        foreach ($f in @('Scope-Summary.html', 'scope-report.md')) {
            Test-Path (Join-Path $script:Run.RunDir $f) | Should -BeTrue -Because "$f should exist"
        }
        Test-Path (Join-Path $script:Run.RunDir 'raw') | Should -BeTrue
    }

    It 'HTML-encodes a customer workbook name containing an ampersand' {
        # 'SharePoint & OneDrive' is real, from the sample corpus.
        $html = Get-Content (Join-Path $script:Run.RunDir 'Scope-Summary.html') -Raw
        $html | Should -Match 'SharePoint &amp; OneDrive'
    }

    It 'leaves no unexpanded PowerShell variable in the customer-facing reports' {
        # A backtick before $ in a double-quoted string suppresses interpolation,
        # so '$sourceName' was printed literally in the Next Steps section.
        foreach ($file in @('scope-report.md', 'Scope-Summary.html')) {
            $text = Get-Content (Join-Path $script:Run.RunDir $file) -Raw
            $text | Should -Not -Match '\$(sourceName|destName|scoped|reverted|RunResult)\b' -Because "$file should not contain a literal variable name"
        }
    }

    It 'names both workspaces in the permissions next step' {
        # The single likeliest support call. It is worthless if the report cannot
        # say which two workspaces need the grant.
        $md = Get-Content (Join-Path $script:Run.RunDir 'scope-report.md') -Raw
        $md | Should -Match 'Log Analytics Reader'
        $md | Should -Match 'ws-source'
        $md | Should -Match 'ws-dest'
    }
}

Describe 'Failure handling' {

    It 'exits 2 when source and destination are the same workspace' {
        $r = Invoke-Orchestrator -Parameters @{
            DryRun = $true; SkipPreflight = $true
            SourceWorkspace = 'ws-dest'; SourceResourceGroup = 'rg-dest'
            SourceSubscriptionId = '22222222-2222-2222-2222-222222222222'
        }
        $r.ExitCode | Should -Be 2
        ($r.Stdout + $r.Stderr) | Should -Match '(?i)same workspace'
    }

    It 'exits 2 on an out-of-range parameter rather than looking like success' {
        $r = Invoke-Orchestrator -Parameters @{ DryRun = $true; RetryCount = 99 }
        $r.ExitCode | Should -Not -Be 0
    }

    It 'handles a destination with no matching workbooks without failing' {
        $r = Invoke-Orchestrator -Parameters @{ DryRun = $true; SkipPreflight = $true } -NoWorkbooks
        $r.ExitCode | Should -Be 0 -Because "stdout was:`n$($r.Stdout)`n$($r.Stderr)"
        $r.Stdout | Should -Match '(?i)no workbooks matched'
    }
}

Describe 'Revert' {

    It 'restores destination-only scope and exits zero' {
        $r = Invoke-Orchestrator -Parameters @{ Execute = $true; Force = $true; Revert = $true; SkipPreflight = $true }
        $r.ExitCode | Should -Be 0 -Because "stdout was:`n$($r.Stdout)`n$($r.Stderr)"
    }

    It 'proceeds with preflight ON when the source workspace has been deleted' {
        # The recovery path. Reverting is what you do *because* the source is
        # going away, so its absence must not fail the run - it previously exited
        # 2, stranding whoever decommissioned before reverting and pushing them
        # onto -SkipPreflight, which also disables the destination checks.
        $r = Invoke-Orchestrator -SourceDeleted -Parameters @{ Execute = $true; Force = $true; Revert = $true }
        $r.ExitCode | Should -Be 0 -Because "stdout was:`n$($r.Stdout)`n$($r.Stderr)"
        $r.Stdout | Should -Match '(?i)expected when reverting'
    }

    It 'still refuses to apply scope when the source workspace has been deleted' {
        $r = Invoke-Orchestrator -SourceDeleted -Parameters @{ Execute = $true; Force = $true }
        $r.ExitCode | Should -Be 2
        ($r.Stdout + $r.Stderr) | Should -Match '(?i)source workspace is not reachable'
    }
}

Describe 'Scope mode' {

    It 'defaults to literal and says so' {
        $r = Invoke-Orchestrator -Parameters @{ Execute = $true; Force = $true; SkipPreflight = $true }
        $r.ExitCode | Should -Be 0 -Because "stdout was:`n$($r.Stdout)`n$($r.Stderr)"
        $r.Stdout | Should -Match 'Scope mode:\s+Literal'
    }

    It 'honours -ScopeMode SelfHealing when asked for it' {
        $r = Invoke-Orchestrator -Parameters @{ Execute = $true; Force = $true; SkipPreflight = $true; ScopeMode = 'SelfHealing' }
        $r.ExitCode | Should -Be 0 -Because "stdout was:`n$($r.Stdout)`n$($r.Stderr)"
        $r.Stdout | Should -Match 'Scope mode:\s+SelfHealing'
    }

    It 'rejects an unknown scope mode at bind time' {
        $r = Invoke-Orchestrator -Parameters @{ DryRun = $true; SkipPreflight = $true; ScopeMode = 'Magic' }
        $r.ExitCode | Should -Not -Be 0
    }
}

AfterAll {
    Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'wbscope-smoke-*' -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
