<#
.SYNOPSIS
    Runs the Pester suite as a pre-push gate.

.DESCRIPTION
    Invoked by tools/hooks/pre-push. Exits non-zero when any test fails, which
    causes git to abort the push.

    This exists because GitHub Actions does not execute in this repository - the
    account is an Enterprise Managed User and Actions is disabled by enterprise
    policy on personal private repos. The workflow file is present and valid, but
    it produces no check runs. Until that changes, this hook is the automated gate.

.NOTES
    Bypass with:  git push --no-verify
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$testPath = Join-Path $repoRoot 'tests'

Write-Host ''
Write-Host 'pre-push: running Pester suite...' -ForegroundColor Cyan

if (-not (Test-Path $testPath)) {
    Write-Host "pre-push: no tests directory at $testPath - nothing to check." -ForegroundColor Yellow
    exit 0
}

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    Write-Host ''
    Write-Host 'pre-push: Pester 5+ is not installed, so the tests cannot run.' -ForegroundColor Red
    Write-Host '          Install it with:' -ForegroundColor Red
    Write-Host ''
    Write-Host '              Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck' -ForegroundColor Red
    Write-Host ''
    Write-Host '          Or bypass this check with:  git push --no-verify' -ForegroundColor Red
    Write-Host ''
    exit 1
}

Import-Module Pester -MinimumVersion 5.0.0 -Force

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$config = New-PesterConfiguration
$config.Run.Path = $testPath
$config.Run.PassThru = $true
$config.Output.Verbosity = 'None'

$result = Invoke-Pester -Configuration $config 6>$null

$stopwatch.Stop()

if ($result.FailedCount -gt 0) {
    Write-Host ''
    Write-Host ("pre-push: {0} of {1} test(s) FAILED - push aborted." -f $result.FailedCount, $result.TotalCount) -ForegroundColor Red
    Write-Host ''

    foreach ($failure in $result.Failed) {
        Write-Host ("  x {0}" -f $failure.ExpandedPath) -ForegroundColor Red
        if ($failure.ErrorRecord) {
            $message = ($failure.ErrorRecord | Out-String).Trim()
            foreach ($line in ($message -split "`r?`n" | Select-Object -First 4)) {
                Write-Host ("      {0}" -f $line) -ForegroundColor DarkGray
            }
        }
    }

    Write-Host ''
    Write-Host '  Re-run locally to iterate:  Invoke-Pester -Path ./tests -Output Detailed' -ForegroundColor Yellow
    Write-Host '  Bypass deliberately:        git push --no-verify' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

Write-Host ("pre-push: {0}/{1} tests passed in {2:N0}s." -f $result.PassedCount, $result.TotalCount, $stopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
if ($result.SkippedCount -gt 0) {
    # Worth surfacing: without it, a run where tests were skipped still reads as a
    # clean pass, and the format string previously used PassedCount for both halves
    # so the totals always agreed no matter how many tests never ran.
    Write-Host ("pre-push: {0} test(s) skipped." -f $result.SkippedCount) -ForegroundColor Yellow
}

# This suite is offline. Every assertion in it runs against JSON this tool
# produced itself, with the network stubbed. It cannot observe how the Azure
# Workbooks engine renders a scoped workbook, which is what actually decides
# whether the tool works. A green run here has previously been reported as
# "verified" while the tool returned no historical data in a customer tenant.
$liveRan = @($result.Tests | Where-Object { $_.Tag -contains 'Live' -and $_.Result -eq 'Passed' }).Count
if ($liveRan -eq 0) {
    Write-Host ''
    Write-Host 'pre-push: this is the OFFLINE suite. Live Azure verification did not run.' -ForegroundColor Yellow
    Write-Host '          Passing here does not mean the tool works against Azure.' -ForegroundColor Yellow
    Write-Host '          See tests/Live.Azure.Tests.ps1 before claiming it is verified.' -ForegroundColor Yellow
}
Write-Host ''
exit 0
