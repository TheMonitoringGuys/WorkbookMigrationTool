<#
.SYNOPSIS
    Builds a disposable lab for tests/Live.Azure.Tests.ps1.

.DESCRIPTION
    The live suite needs three things that a fresh subscription does not have:

      1. Two Log Analytics workspaces, playing source and destination.
      2. A table holding rows in BOTH of them. Without that, the suite's central
         assertion - that a scoped workbook returns data from both workspaces -
         cannot distinguish "scope is broken" from "there was nothing to return".
      3. At least one Sentinel-category workbook bound to the destination
         workspace, carrying a Log Analytics query for the tool to scope.

    Data is seeded by pointing the subscription's Activity Log at both
    workspaces, which populates AzureActivity within a few minutes and needs no
    virtual machines. The HTTP Data Collector API is deliberately not used: its
    support ends on 14 September 2026.

    Two workbooks are created, covering the two shapes that behave differently:
    a query with no explicit scope, and a query driven by a workspace picker.
    Both are tagged MigratedFromWorkbookId so they look like the output of the
    Sentinel Migration Assistant, which is what the tool selects by default.

    Idempotent. Re-running updates in place rather than duplicating.

.PARAMETER SubscriptionId
    Subscription to build the lab in. Defaults to the current context.

.PARAMETER ResourceGroupName
    Resource group for both workspaces. Created if absent.

.PARAMETER Location
    Azure region. Defaults to eastus.

.PARAMETER SourceWorkspaceName
    Name for the workspace playing the old environment.

.PARAMETER DestinationWorkspaceName
    Name for the workspace playing the new environment, where workbooks live.

.PARAMETER SkipActivityLog
    Do not create subscription diagnostic settings. Use when you intend to seed
    data another way, or lack permission at subscription scope.

.PARAMETER WhatIf
    Report what would be created and write nothing.

.EXAMPLE
    Connect-AzAccount
    ./tools/New-ScopeLab.ps1 -ResourceGroupName rg-wbscope-lab

.NOTES
    For a disposable lab only. It creates workbooks and changes subscription
    diagnostic settings. Remove the whole thing by deleting the resource group
    and the two diagnostic settings it names on completion.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$Location = 'eastus',
    [string]$SourceWorkspaceName = 'wbscope-lab-source',
    [string]$DestinationWorkspaceName = 'wbscope-lab-dest',
    [switch]$SkipActivityLog
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\WorkbookScope.Api.psm1') -Force -DisableNameChecking

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) { throw 'Not signed in. Run Connect-AzAccount first.' }
if (-not $SubscriptionId) { $SubscriptionId = [string]$ctx.Subscription.Id }
if (-not $SubscriptionId) { throw 'No subscription in context; pass -SubscriptionId.' }

$arm = Resolve-ArmEndpoint -Cloud 'Commercial'

function Write-Step { param([string]$Text) Write-Host "  $Text" -ForegroundColor Cyan }
function Write-Done { param([string]$Text) Write-Host "    $Text" -ForegroundColor Green }

Write-Host ''
Write-Host 'Building Workbook Scope lab' -ForegroundColor White
Write-Host ('-' * 78) -ForegroundColor DarkGray
Write-Host "  subscription : $SubscriptionId" -ForegroundColor White
Write-Host "  group        : $ResourceGroupName ($Location)" -ForegroundColor White
Write-Host ''

# ── Resource group ───────────────────────────────────────────────────────────
Write-Step 'Resource group'
if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Create resource group')) {
    $null = Invoke-ScopeApi -Method PUT -Body @{ location = $Location } `
        -Uri "$arm/subscriptions/$SubscriptionId/resourcegroups/$ResourceGroupName`?api-version=2021-04-01"
    Write-Done "$ResourceGroupName ready"
}

# ── Workspaces ───────────────────────────────────────────────────────────────
function New-LabWorkspace {
    param([string]$Name)

    $uri = "$arm/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$Name`?api-version=2023-09-01"
    if (-not $PSCmdlet.ShouldProcess($Name, 'Create Log Analytics workspace')) { return $null }

    $null = Invoke-ScopeApi -Method PUT -Uri $uri -Body @{
        location   = $Location
        properties = @{ sku = @{ name = 'PerGB2018' }; retentionInDays = 30 }
    }

    # Provisioning is asynchronous; the customerId is needed by the live suite
    # and is not present until it completes.
    $ws = $null
    for ($i = 0; $i -lt 30; $i++) {
        $ws = Invoke-ScopeApi -Method GET -Uri $uri
        if ($ws.properties.customerId -and $ws.properties.provisioningState -eq 'Succeeded') { break }
        Start-Sleep -Seconds 5
    }
    Write-Done "$Name  ($($ws.properties.customerId))"
    return $ws
}

Write-Step 'Workspaces'
$srcWs = New-LabWorkspace -Name $SourceWorkspaceName
$dstWs = New-LabWorkspace -Name $DestinationWorkspaceName

$srcId = Get-WorkspaceResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $SourceWorkspaceName
$dstId = Get-WorkspaceResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $DestinationWorkspaceName

# ── Seed data ────────────────────────────────────────────────────────────────
# Both workspaces receive the subscription Activity Log, so AzureActivity holds
# rows in each. Any Azure operation - including this script - generates more.
if (-not $SkipActivityLog) {
    Write-Step 'Activity Log to both workspaces (seeds AzureActivity)'
    foreach ($pair in @(
            @{ Name = 'wbscope-lab-src'; Target = $srcId },
            @{ Name = 'wbscope-lab-dst'; Target = $dstId })) {

        if (-not $PSCmdlet.ShouldProcess($pair.Name, 'Create subscription diagnostic setting')) { continue }
        try {
            $null = Invoke-ScopeApi -Method PUT `
                -Uri "$arm/subscriptions/$SubscriptionId/providers/Microsoft.Insights/diagnosticSettings/$($pair.Name)?api-version=2021-05-01-preview" `
                -Body @{
                    properties = @{
                        workspaceId = $pair.Target
                        logs        = @(
                            @{ category = 'Administrative'; enabled = $true }
                            @{ category = 'Policy'; enabled = $true }
                            @{ category = 'ResourceHealth'; enabled = $true }
                        )
                    }
                }
            Write-Done "$($pair.Name) -> $(Split-Path $pair.Target -Leaf)"
        }
        catch {
            Write-Warning "  Could not create '$($pair.Name)': $($_.Exception.Message)"
            Write-Warning '  Needs write access at subscription scope. Re-run with -SkipActivityLog and seed data another way.'
        }
    }
}

# ── Workbooks ────────────────────────────────────────────────────────────────
# Deterministic GUIDs so re-running updates rather than duplicating.
function Get-StableGuid {
    param([string]$Text)
    $bytes = [System.Security.Cryptography.MD5]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text))
    return ([guid]::new($bytes)).ToString()
}

$schema = 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'

# Shape 1: a query with no explicit scope. It inherits the workbook default, so
# after migration it reads the destination only. The tool adds
# crossComponentResources.
$unscoped = [ordered]@{
    version             = 'Notebook/1.0'
    items               = @(
        [ordered]@{
            type    = 3
            name    = 'query-no-explicit-scope'
            content = [ordered]@{
                version      = 'KqlItem/1.0'
                query        = "AzureActivity`n| summarize Events = count() by bin(TimeGenerated, 1h)`n| order by TimeGenerated asc"
                size         = 0
                queryType    = 0
                resourceType = 'microsoft.operationalinsights/workspaces'
                visualization = 'timechart'
            }
        }
    )
    fallbackResourceIds = @($dstId)
    '$schema'           = $schema
}

# Shape 2: a query driven by a workspace picker. The tool patches the parameter
# rather than the query, and this is the shape most likely to re-resolve at
# render time and silently drop the source - the failure the live suite exists
# to detect.
$picker = [ordered]@{
    version             = 'Notebook/1.0'
    items               = @(
        [ordered]@{
            type    = 9
            name    = 'parameters'
            content = [ordered]@{
                version    = 'KqlParameterItem/1.0'
                parameters = @(
                    [ordered]@{
                        id           = [guid]::NewGuid().ToString()
                        version      = 'KqlParameterItem/1.0'
                        name         = 'Workspace'
                        type         = 5
                        isRequired   = $true
                        multiSelect  = $false
                        value        = $dstId
                        typeSettings = [ordered]@{
                            resourceTypeFilter = [ordered]@{ 'microsoft.operationalinsights/workspaces' = $true }
                            additionalResourceOptions = @()
                        }
                    }
                )
            }
        }
        [ordered]@{
            type    = 3
            name    = 'query-via-picker'
            content = [ordered]@{
                version                 = 'KqlItem/1.0'
                query                   = "AzureActivity`n| summarize Events = count() by OperationNameValue`n| top 10 by Events desc"
                size                    = 0
                queryType               = 0
                resourceType            = 'microsoft.operationalinsights/workspaces'
                crossComponentResources = @('{Workspace}')
                visualization           = 'table'
            }
        }
    )
    fallbackResourceIds = @($dstId)
    '$schema'           = $schema
}

Write-Step 'Workbooks in the destination'
$created = @()
foreach ($wb in @(
        @{ Title = 'WBScope Lab - unscoped query'; Doc = $unscoped },
        @{ Title = 'WBScope Lab - picker query'; Doc = $picker })) {

    $id = Get-StableGuid -Text "$dstId|$($wb.Title)"
    if (-not $PSCmdlet.ShouldProcess($wb.Title, 'Create workbook')) { continue }

    $null = Invoke-ScopeApi -Method PUT `
        -Uri (Get-WorkbookUri -ArmEndpoint $arm -SubscriptionId $SubscriptionId `
                -ResourceGroupName $ResourceGroupName -WorkbookId $id) `
        -Body @{
            location   = $Location
            kind       = 'shared'
            # Marks these as migration output, which is what the tool selects by
            # default. Without it the live suite only finds them via
            # -IncludeAllWorkbooks.
            tags       = @{ MigratedFromWorkbookId = "lab-$($id.Substring(0,8))" }
            properties = @{
                displayName    = $wb.Title
                serializedData = ($wb.Doc | ConvertTo-Json -Depth 100 -Compress)
                category       = 'sentinel'
                sourceId       = $dstId
                version        = 'Notebook/1.0'
            }
        }
    Write-Done $wb.Title
    $created += $wb.Title
}

# ── Report ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host 'Lab ready.' -ForegroundColor Green
Write-Host ''
Write-Host 'Set these, then run the live suite:' -ForegroundColor White
Write-Host ''
$env:WBSCOPE_LAB_SRC_SUB = $SubscriptionId
$env:WBSCOPE_LAB_SRC_RG = $ResourceGroupName
$env:WBSCOPE_LAB_SRC_WS = $SourceWorkspaceName
$env:WBSCOPE_LAB_DST_SUB = $SubscriptionId
$env:WBSCOPE_LAB_DST_RG = $ResourceGroupName
$env:WBSCOPE_LAB_DST_WS = $DestinationWorkspaceName
$env:WBSCOPE_LAB_TABLE = 'AzureActivity'

@"
`$env:WBSCOPE_LAB_SRC_SUB = '$SubscriptionId'
`$env:WBSCOPE_LAB_SRC_RG  = '$ResourceGroupName'
`$env:WBSCOPE_LAB_SRC_WS  = '$SourceWorkspaceName'
`$env:WBSCOPE_LAB_DST_SUB = '$SubscriptionId'
`$env:WBSCOPE_LAB_DST_RG  = '$ResourceGroupName'
`$env:WBSCOPE_LAB_DST_WS  = '$DestinationWorkspaceName'
`$env:WBSCOPE_LAB_TABLE   = 'AzureActivity'

Invoke-Pester -Path ./tests/Live.Azure.Tests.ps1 -Output Detailed
"@ | Write-Host -ForegroundColor Green

Write-Host ''
Write-Host 'They are already set in THIS session, so you can run the suite now.' -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Activity Log data takes 5-15 minutes to appear in a new workspace. The' -ForegroundColor Yellow
Write-Host 'suite checks this first and says so rather than failing obscurely - if' -ForegroundColor Yellow
Write-Host 'the precondition about both workspaces returning rows fails, wait and' -ForegroundColor Yellow
Write-Host 'run it again.' -ForegroundColor Yellow
Write-Host ''
Write-Host "Tear down:  Remove-AzResourceGroup -Name $ResourceGroupName -Force" -ForegroundColor DarkGray
Write-Host '            then delete diagnostic settings wbscope-lab-src / wbscope-lab-dst' -ForegroundColor DarkGray
Write-Host ''
