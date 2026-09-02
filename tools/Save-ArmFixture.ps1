<#
.SYNOPSIS
    Records real ARM responses from a lab into fixtures for contract tests.

.DESCRIPTION
    Every fixture in tests/fixtures was written by hand. They encode what this
    tool believes Azure returns, so the tests that use them can only confirm the
    tool agrees with itself - which is the defect this whole effort exists to
    remove.

    This captures what ARM actually returns, so tests/ArmContract.Tests.ps1 can
    check the tool's assumptions against the real shape rather than an assumed
    one.

    Read-only against Azure. It issues GETs and writes files locally.

    Sanitising is on by default: subscription GUIDs, workspace GUIDs, tenant
    IDs and resource names are replaced with stable placeholders, because the
    recorded fixtures are committed to a public repository. Pass -NoSanitize
    only for a throwaway local capture you do not intend to commit.

.PARAMETER SubscriptionId
    Subscription holding the workbooks. Defaults to the current context.

.PARAMETER ResourceGroupName
    Resource group holding the workbooks and workspace.

.PARAMETER WorkspaceName
    Workspace the workbooks are bound to.

.PARAMETER OutputPath
    Where to write the recording. Defaults to tests/fixtures/recorded.

.PARAMETER NoSanitize
    Keep real identifiers. Do not commit the result.

.EXAMPLE
    Connect-AzAccount
    ./tools/Save-ArmFixture.ps1 -ResourceGroupName rg-wbscope-lab -WorkspaceName wbscope-lab-dest

.NOTES
    Run this against the lab built by tools/New-ScopeLab.ps1, or against any
    environment whose workbook shapes you want the contract tests to cover.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$WorkspaceName,
    [string]$OutputPath,
    [switch]$NoSanitize
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\WorkbookScope.Api.psm1') -Force -DisableNameChecking

if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot 'tests\fixtures\recorded' }

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) { throw 'Not signed in. Run Connect-AzAccount first.' }
if (-not $SubscriptionId) { $SubscriptionId = [string]$ctx.Subscription.Id }

$arm = Resolve-ArmEndpoint -Cloud 'Commercial'
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Host ''
Write-Host 'Recording ARM responses' -ForegroundColor White
Write-Host ('-' * 70) -ForegroundColor DarkGray

# ── Capture ──────────────────────────────────────────────────────────────────
Write-Host '  workspace GET' -ForegroundColor Cyan
$wsUri = Get-WorkspaceUriWithVersion -WorkspaceUri (
    Get-ScopeWorkspaceUri -ArmEndpoint $arm -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName)
$workspace = Invoke-ScopeApi -Uri $wsUri -Method GET

$wsResourceId = Get-WorkspaceResourceId -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName

Write-Host '  workbook list (with content)' -ForegroundColor Cyan
$listUri = Get-WorkbooksUri -ArmEndpoint $arm -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -SourceId $wsResourceId
$workbooks = @(Invoke-ScopeApiList -Uri $listUri)
Write-Host "    $($workbooks.Count) workbook(s)" -ForegroundColor Green

# The per-item GET is a different code path with a different response shape, and
# the tool falls back to it when the bulk listing is rejected. Recording only the
# list would leave that path still validated against an assumption.
$item = $null
if ($workbooks.Count -gt 0) {
    Write-Host '  workbook item GET' -ForegroundColor Cyan
    $item = Invoke-ScopeApi -Method GET -Uri (
        Get-WorkbookUri -ArmEndpoint $arm -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -WorkbookId (($workbooks[0].id -split '/')[-1]) -IncludeContent)
}

# ── Sanitise ─────────────────────────────────────────────────────────────────
# Applied to the serialised JSON so it reaches identifiers wherever they appear,
# including inside the serializedData string, which is where workspace IDs are
# embedded and would otherwise survive a property-by-property scrub.
function Protect-Recording {
    param([string]$Json)

    if ($NoSanitize) { return $Json }

    $map = [ordered]@{
        $SubscriptionId    = '00000000-0000-0000-0000-000000000001'
        $ResourceGroupName = 'rg-recorded'
        $WorkspaceName     = 'ws-recorded'
    }
    if ($workspace.properties.customerId) {
        $map[[string]$workspace.properties.customerId] = '00000000-0000-0000-0000-0000000000ff'
    }
    if ($ctx.Tenant -and $ctx.Tenant.Id) {
        $map[[string]$ctx.Tenant.Id] = '00000000-0000-0000-0000-00000000000t'
    }

    foreach ($k in $map.Keys) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        $Json = $Json -replace [regex]::Escape($k), $map[$k]
    }

    # Anything still shaped like a GUID belongs to a resource this script did not
    # name - a user ID on a workbook, a linked resource. Blanked rather than
    # mapped, since the contract tests care about shape, not identity.
    $Json = [regex]::Replace($Json, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
        { param($m) if ($m.Value -like '00000000-*') { $m.Value } else { '11111111-2222-3333-4444-555555555555' } })

    return $Json
}

$recording = [ordered]@{
    '$recordingSchema' = 1
    recordedUtc        = (Get-Date).ToUniversalTime().ToString('o')
    sanitized          = (-not $NoSanitize)
    apiVersions        = [ordered]@{
        workbooks  = Get-ScopeApiVersion 'workbooks'
        workspaces = Get-ScopeApiVersion 'workspaces'
    }
    workspace          = $workspace
    workbookList       = $workbooks
    workbookItem       = $item
}

$json = Protect-Recording -Json ($recording | ConvertTo-Json -Depth 100)
$outFile = Join-Path $OutputPath 'arm-responses.json'
$json | Set-Content -Path $outFile -Encoding UTF8

Write-Host ''
Write-Host "Recorded to: $outFile" -ForegroundColor Green
if (-not $NoSanitize) {
    Write-Host 'Identifiers were replaced with placeholders. Read the file before committing.' -ForegroundColor Yellow
}
else {
    Write-Host 'NOT sanitized - contains real identifiers. Do not commit this file.' -ForegroundColor Red
}
Write-Host ''
Write-Host 'The contract tests pick it up automatically:' -ForegroundColor White
Write-Host '   Invoke-Pester -Path ./tests/ArmContract.Tests.ps1 -Output Detailed' -ForegroundColor Green
Write-Host ''
