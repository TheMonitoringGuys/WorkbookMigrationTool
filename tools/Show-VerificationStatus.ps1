<#
.SYNOPSIS
    States, in one word, whether this tool has been verified against live Azure.

.DESCRIPTION
    This exists because "it works" has been reported for this tool several times
    while it did not, and every one of those reports was made in good faith from
    evidence that looked conclusive:

      - a green offline suite, which only proves the tool agrees with itself
      - a clean run report, which describes what the tool wrote, not what Azure
        rendered
      - data present in both workspaces, which proves the LAB is seeded, not
        that a scoped workbook reads both
      - a live suite that silently SKIPPED, which looks almost identical to one
        that passed

    Pester prints [!] for a skipped test and [+] for a passing one. In a wall of
    output that difference is one character, and it is the difference between
    verified and not.

    This runs the live suite and reduces it to a single unambiguous verdict.
    It never reports success from a skipped test.

.PARAMETER Detailed
    Also show the full Pester output.

.EXAMPLE
    ./tools/Show-VerificationStatus.ps1

.NOTES
    Set the lab variables first, in the SAME shell:

        $env:WBSCOPE_LAB_SRC_SUB = '...'
        $env:WBSCOPE_LAB_SRC_RG  = '...'
        $env:WBSCOPE_LAB_SRC_WS  = '...'
        $env:WBSCOPE_LAB_DST_SUB = '...'
        $env:WBSCOPE_LAB_DST_RG  = '...'
        $env:WBSCOPE_LAB_DST_WS  = '...'

    tools/New-ScopeLab.ps1 sets them for you in the session that runs it.
#>

[CmdletBinding()]
param([switch]$Detailed)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$liveTests = Join-Path $repoRoot 'tests\Live.Azure.Tests.ps1'

# The one assertion that proves the tool works. Named here so the verdict can
# key off it specifically rather than off an aggregate pass count, which a
# skipped test would not reduce.
$provingTest = 'returns data from BOTH workspaces through a scoped workbook query'

function Write-Rule { Write-Host ('-' * 74) -ForegroundColor DarkGray }

Write-Host ''
Write-Host 'Verification status' -ForegroundColor White
Write-Rule

# ── Are the lab variables present? ───────────────────────────────────────────
$required = @(
    'WBSCOPE_LAB_SRC_SUB', 'WBSCOPE_LAB_SRC_RG', 'WBSCOPE_LAB_SRC_WS',
    'WBSCOPE_LAB_DST_SUB', 'WBSCOPE_LAB_DST_RG', 'WBSCOPE_LAB_DST_WS'
)
$missing = @($required | Where-Object { -not [Environment]::GetEnvironmentVariable($_) })

if ($missing.Count -gt 0) {
    Write-Host '  NOT VERIFIED' -ForegroundColor Red
    Write-Host ''
    Write-Host '  The live suite cannot run: the lab variables are not set in this shell.' -ForegroundColor Yellow
    Write-Host "  Missing: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  They must be set in the SAME shell that runs the tests. Setting them in' -ForegroundColor Yellow
    Write-Host '  another window, or in a script that has since exited, will not carry over -' -ForegroundColor Yellow
    Write-Host '  and the suite then skips rather than failing, which reads like success.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Build a lab and set them:  ./tools/New-ScopeLab.ps1 -ResourceGroupName <rg>' -ForegroundColor Green
    Write-Host ''
    exit 2
}

Write-Host "  Lab configured: $($env:WBSCOPE_LAB_SRC_WS) -> $($env:WBSCOPE_LAB_DST_WS)" -ForegroundColor White

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    Write-Host ''
    Write-Host '  NOT VERIFIED' -ForegroundColor Red
    Write-Host '  Not signed in to Azure. Run Connect-AzAccount.' -ForegroundColor Yellow
    Write-Host ''
    exit 2
}
Write-Host "  Running as:     $($ctx.Account.Id)" -ForegroundColor White
Write-Host ''
Write-Host '  Running the live suite against Azure...' -ForegroundColor Cyan

Import-Module Pester -MinimumVersion 5.0 -Force

$config = New-PesterConfiguration
$config.Run.Path = $liveTests
$config.Run.PassThru = $true
$config.Output.Verbosity = if ($Detailed) { 'Detailed' } else { 'None' }

$result = if ($Detailed) { Invoke-Pester -Configuration $config } else { Invoke-Pester -Configuration $config 6>$null }

# ── Verdict ──────────────────────────────────────────────────────────────────
# Keyed off the proving assertion by name. An aggregate count would report
# success for a run where that test skipped and the cheaper ones passed.
$proving = $result.Tests | Where-Object { $_.Name -eq $provingTest }
$live = @($result.Tests | Where-Object { $_.Tag -contains 'Live' })
$ran = @($live | Where-Object { $_.Result -eq 'Passed' })
$skipped = @($live | Where-Object { $_.Result -eq 'Skipped' })
$failed = @($live | Where-Object { $_.Result -eq 'Failed' })

Write-Host ''
Write-Rule

if ($failed.Count -gt 0) {
    Write-Host '  NOT VERIFIED - the live suite FAILED' -ForegroundColor Red
    Write-Host ''
    foreach ($f in $failed) {
        Write-Host "    x $($f.Name)" -ForegroundColor Red
        if ($f.ErrorRecord) {
            $msg = ($f.ErrorRecord | Out-String).Trim() -split "`r?`n" | Select-Object -First 3
            foreach ($line in $msg) { Write-Host "        $line" -ForegroundColor DarkGray }
        }
    }
    Write-Host ''
    Write-Host '  This is a real result, and more useful than a green offline suite.' -ForegroundColor Yellow
    Write-Host '  Re-run with -Detailed for the full output.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

if (-not $proving -or $proving.Result -ne 'Passed') {
    $state = if ($proving) { $proving.Result } else { 'not found' }
    Write-Host '  NOT VERIFIED' -ForegroundColor Red
    Write-Host ''
    Write-Host "  The assertion that proves the tool works did not pass. It was: $state" -ForegroundColor Yellow
    Write-Host "    '$provingTest'" -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  Live tests passed: $($ran.Count), skipped: $($skipped.Count)" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  A skipped live suite is not a passing one. Nothing here yet shows that a' -ForegroundColor Yellow
    Write-Host '  scoped workbook returns data from both workspaces.' -ForegroundColor Yellow
    Write-Host ''
    exit 2
}

Write-Host '  VERIFIED against live Azure' -ForegroundColor Green
Write-Host ''
Write-Host "  $($ran.Count) live test(s) passed, including the one that matters:" -ForegroundColor Green
Write-Host "    '$provingTest'" -ForegroundColor Green
Write-Host ''
Write-Host '  A scoped workbook was read back out of ARM and its query returned rows' -ForegroundColor Green
Write-Host '  from BOTH workspaces. That is the claim; it now has evidence.' -ForegroundColor Green
Write-Host ''
Write-Host '  Still NOT covered by this result:' -ForegroundColor Yellow
Write-Host '    - Whether the Workbooks renderer honours the scope for a LOW-PRIVILEGE' -ForegroundColor Yellow
Write-Host '      viewer. These queries ran as the identity above. If that identity is an' -ForegroundColor Yellow
Write-Host '      Owner, this says nothing about the people reporting empty tiles.' -ForegroundColor Yellow
Write-Host '      Open a scoped workbook in the portal as someone holding Log Analytics' -ForegroundColor Yellow
Write-Host '      Reader on the DESTINATION ONLY, and see whether it renders history.' -ForegroundColor Yellow
Write-Host '    - Content Hub solution updates reverting scoping on their own workbooks.' -ForegroundColor Yellow
Write-Host ''
exit 0
