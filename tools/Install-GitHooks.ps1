<#
.SYNOPSIS
    Installs the repository's git hooks.

.DESCRIPTION
    Points git's core.hooksPath at tools/hooks, which enables the pre-push hook
    that runs the Pester suite before every push.

    Why this exists rather than relying on CI: GitHub Actions does not execute in
    this repository. The account is an Enterprise Managed User, and Actions is
    disabled by enterprise policy on personal private repos. .github/workflows/tests.yml
    is valid and will start working if the repo moves to an org, but today it
    produces no check runs. This hook is the gate that actually runs.

    Safe to run repeatedly.

.PARAMETER Uninstall
    Removes the core.hooksPath setting, restoring git's default .git/hooks.

.EXAMPLE
    ./tools/Install-GitHooks.ps1

.EXAMPLE
    ./tools/Install-GitHooks.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host "  $Message" }

Write-Host ''
Write-Host 'Sentinel Workbook Scope Assistant - git hooks' -ForegroundColor Cyan
Write-Host ''

# Resolve the repo this script actually lives in, rather than trusting the caller's
# working directory. Running the installer from elsewhere should still be correct.
$repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
    Write-Host '  Not inside a git repository - nothing to do.' -ForegroundColor Red
    exit 1
}
$repoRoot = $repoRoot.Trim()

if ($Uninstall) {
    $current = (& git -C $repoRoot config --local --get core.hooksPath 2>$null)
    if ([string]::IsNullOrWhiteSpace($current)) {
        Write-Step 'core.hooksPath is not set - nothing to remove.'
    }
    else {
        & git -C $repoRoot config --local --unset core.hooksPath
        Write-Step "Removed core.hooksPath (was '$($current.Trim())')."
        Write-Step 'Pushes are no longer gated by the test suite.'
    }
    Write-Host ''
    exit 0
}

# A relative path matters here. Git resolves a relative core.hooksPath against the
# top level of the working tree, so a single setting works correctly in the main
# clone and in every worktree. An absolute path would silently point every worktree
# at one clone's scripts.
$hooksPath = 'tools/hooks'
& git -C $repoRoot config --local core.hooksPath $hooksPath
Write-Step "core.hooksPath -> $hooksPath"

# On Unix Git requires the hook to be executable. Record the bit in the index so a
# fresh clone on macOS or Linux gets a hook that actually runs.
$hookFile = Join-Path $repoRoot 'tools/hooks/pre-push'
if (Test-Path $hookFile) {
    if (-not $IsWindows) {
        & chmod +x $hookFile 2>$null
    }
    $mode = (& git -C $repoRoot ls-files --stage -- 'tools/hooks/pre-push' 2>$null)
    if ($mode -and $mode -notmatch '^100755') {
        & git -C $repoRoot update-index --chmod=+x 'tools/hooks/pre-push' 2>$null
        Write-Step 'Marked tools/hooks/pre-push executable in the index.'
    }
}
else {
    Write-Host "  WARNING: $hookFile is missing - the hook will not run." -ForegroundColor Yellow
}

Write-Host ''
Write-Step 'Checking prerequisites:'

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($pester) {
    Write-Host "    Pester $($pester.Version) - OK" -ForegroundColor Green
}
else {
    Write-Host '    Pester 5+ - MISSING' -ForegroundColor Yellow
    Write-Host '      Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  Done. The full suite now runs before each push.' -ForegroundColor Green
Write-Host '  Bypass a single push with:  git push --no-verify' -ForegroundColor DarkGray
Write-Host ''
