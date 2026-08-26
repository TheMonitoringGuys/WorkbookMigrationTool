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

Write-Host ("pre-push: {0}/{0} tests passed in {1:N0}s." -f $result.PassedCount, $stopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host ''
exit 0
