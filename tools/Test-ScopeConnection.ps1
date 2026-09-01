<#
.SYNOPSIS
    Checks that this machine can authenticate to Azure and read workbooks, and
    reports exactly which step fails.

.DESCRIPTION
    Written for one specific support case that was expensive to diagnose. A run
    failed with:

        HTTP 502 on GET .../Microsoft.Insights/workbooks?... - Forbidden:
        Authentication information is not given in the correct format. Check the
        value of Authorization header.

    That message reads like a permissions problem. It is not. Azure is saying the
    Authorization header it received was malformed, so the request never got as
    far as evaluating access. The cause is on the client, and the useful evidence
    lives in what Get-AzAccessToken returned - which the main tool never showed.

    This script captures that evidence. It reports the token's shape, never its
    value: no token, or any fragment of one, is printed or written to disk. The
    preview in a failure message is truncated to twelve characters, which is
    enough to tell a JWT from an error string and not enough to be a credential.

    Safe to run against production. It performs one read.

.PARAMETER SubscriptionId
    Subscription containing the destination workspace.

.PARAMETER ResourceGroupName
    Resource group containing the destination workspace.

.PARAMETER WorkspaceName
    Destination Log Analytics workspace name.

.EXAMPLE
    ./tools/Test-ScopeConnection.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName my-sentinel-rg -WorkspaceName my-sentinel-workspace

.NOTES
    Send the whole output to whoever is helping. It contains no secrets.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$WorkspaceName
)

$ErrorActionPreference = 'Stop'

function Write-Check {
    param([string]$Label, [string]$Value, [ValidateSet('ok', 'bad', 'info')][string]$State = 'info')
    $mark = switch ($State) { 'ok' { '  OK  ' } 'bad' { ' FAIL ' } default { '      ' } }
    $colour = switch ($State) { 'ok' { 'Green' } 'bad' { 'Red' } default { 'Gray' } }
    Write-Host $mark -ForegroundColor $colour -NoNewline
    Write-Host ("{0,-34}" -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor Cyan
}

Write-Host ''
Write-Host 'Workbook Scope Assistant - connection check' -ForegroundColor White
Write-Host ('-' * 72) -ForegroundColor DarkGray

# ── Environment ───────────────────────────────────────────────────────────────
Write-Check 'PowerShell' $PSVersionTable.PSVersion.ToString()

$azModule = Get-Module -ListAvailable Az.Accounts | Sort-Object Version -Descending | Select-Object -First 1
if (-not $azModule) {
    Write-Check 'Az.Accounts' 'not installed' 'bad'
    Write-Host ''
    Write-Host 'Install it:  Install-Module Az.Accounts -Scope CurrentUser' -ForegroundColor Yellow
    exit 2
}
Write-Check 'Az.Accounts' $azModule.Version.ToString()

# More than one version on the path is worth knowing about: PowerShell loads the
# first it finds, which is not always the newest, and the two can behave
# differently in exactly the area this script is testing.
$allVersions = @(Get-Module -ListAvailable Az.Accounts)
if ($allVersions.Count -gt 1) {
    $list = ($allVersions | Sort-Object Version -Descending | ForEach-Object { $_.Version.ToString() }) -join ', '
    Write-Check 'Az.Accounts versions present' $list 'info'
    Write-Host '       Several versions are installed. The one loaded may not be the newest.' -ForegroundColor Yellow
}

# ── Context ───────────────────────────────────────────────────────────────────
$ctx = $null
try { $ctx = Get-AzContext } catch { }
if (-not $ctx) {
    Write-Check 'Azure context' 'none' 'bad'
    Write-Host ''
    Write-Host 'Sign in first. In tenants that require it:' -ForegroundColor Yellow
    Write-Host '   Connect-AzAccount -UseDeviceAuth' -ForegroundColor Yellow
    exit 2
}
Write-Check 'Signed in as' $ctx.Account.Id 'ok'
Write-Check 'Tenant' $ctx.Tenant.Id
Write-Check 'Context subscription' $ctx.Subscription.Id
Write-Check 'Cloud' $ctx.Environment.Name

# Multiple contexts are the documented way the header ends up holding two tokens
# separated by a space.
$contexts = @(Get-AzContext -ListAvailable -ErrorAction SilentlyContinue)
Write-Check 'Contexts available' $contexts.Count
if ($contexts.Count -gt 1) {
    Write-Host '       More than one context is available. If the token check below reports' -ForegroundColor Yellow
    Write-Host '       whitespace, select one explicitly with Set-AzContext and re-run.' -ForegroundColor Yellow
}

if ($ctx.Subscription.Id -ne $SubscriptionId) {
    Write-Host ''
    Write-Host "       Context is on $($ctx.Subscription.Id) but the workspace is in $SubscriptionId." -ForegroundColor Yellow
    Write-Host "       That is fine for a read, but if the call below fails on access, try:" -ForegroundColor Yellow
    Write-Host "          Set-AzContext -Subscription $SubscriptionId" -ForegroundColor Yellow
}

# ── Token ─────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host 'Token' -ForegroundColor White
Write-Host ('-' * 72) -ForegroundColor DarkGray

$arm = (Get-AzEnvironment -Name $ctx.Environment.Name).ResourceManagerUrl.TrimEnd('/')
Write-Check 'ARM endpoint' $arm

$returned = $null
try {
    # Deliberately NOT collapsed to a single object. How many objects come back is
    # the thing being measured.
    $returned = @(Get-AzAccessToken -ResourceUrl $arm -ErrorAction Stop)
}
catch {
    Write-Check 'Get-AzAccessToken' 'threw' 'bad'
    Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Host 'Sign in again:  Connect-AzAccount -UseDeviceAuth' -ForegroundColor Yellow
    exit 2
}

Write-Check 'Objects returned' $returned.Count $(if ($returned.Count -eq 1) { 'ok' } else { 'bad' })
if ($returned.Count -ne 1) {
    Write-Host '       Expected exactly one. More than one is what produces a header holding' -ForegroundColor Red
    Write-Host '       several tokens joined by spaces, which Azure rejects as malformed.' -ForegroundColor Red
}

$tokenObj = $returned[0]
Write-Check 'Token object type' $tokenObj.GetType().Name

$raw = $tokenObj.Token
$rawType = if ($null -eq $raw) { '(null)' } else { $raw.GetType().Name }
Write-Check 'Token property type' $rawType

if ($raw -is [securestring]) { $raw = $raw | ConvertFrom-SecureString -AsPlainText }
$token = ([string]$raw).Trim()

Write-Check 'Token length' $token.Length $(if ($token.Length -gt 100) { 'ok' } else { 'bad' })
Write-Check 'Looks like a JWT' $($token -match '^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]*$') $(if ($token -match '^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]*$') { 'ok' } else { 'bad' })
Write-Check 'Contains whitespace' $($token -match '\s') $(if ($token -match '\s') { 'bad' } else { 'ok' })

if ($tokenObj.PSObject.Properties['ExpiresOn'] -and $tokenObj.ExpiresOn) {
    $expiry = [datetimeoffset]$tokenObj.ExpiresOn
    $minsLeft = [math]::Round(($expiry - [datetimeoffset]::UtcNow).TotalMinutes)
    Write-Check 'Expires in (minutes)' $minsLeft $(if ($minsLeft -gt 0) { 'ok' } else { 'bad' })
}

$tokenUsable = $token.Length -gt 100 -and $token -notmatch '\s' -and $token -match '^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.'
if (-not $tokenUsable) {
    Write-Host ''
    Write-Host 'The token is not usable as an Authorization header. This is the cause of the' -ForegroundColor Red
    Write-Host 'HTTP 502 "check the value of Authorization header" error. It is not a' -ForegroundColor Red
    Write-Host 'permissions problem.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Try, in order:' -ForegroundColor Yellow
    Write-Host '   1. Disconnect-AzAccount; Connect-AzAccount -UseDeviceAuth' -ForegroundColor Yellow
    Write-Host '   2. Get-AzContext -ListAvailable   then   Set-AzContext -Subscription <id>' -ForegroundColor Yellow
    Write-Host '   3. Update-Module Az.Accounts' -ForegroundColor Yellow
    exit 2
}

# ── The call that failed ──────────────────────────────────────────────────────
Write-Host ''
Write-Host 'Workbook read' -ForegroundColor White
Write-Host ('-' * 72) -ForegroundColor DarkGray

$sourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"
$uri = "$arm/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/workbooks" +
       "?category=sentinel&canFetchContent=true&api-version=2022-04-01&sourceId=$([uri]::EscapeDataString($sourceId))"

Write-Check 'Workspace' $WorkspaceName
Write-Host '       GET .../Microsoft.Insights/workbooks?category=sentinel' -ForegroundColor DarkGray

try {
    $result = Invoke-RestMethod -Uri $uri -Method GET -Headers @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    } -ErrorAction Stop

    $count = @($result.value).Count
    Write-Check 'Workbooks returned' $count 'ok'
    Write-Host ''
    Write-Host 'Authentication and workbook access are both working on this machine.' -ForegroundColor Green
    Write-Host 'If the main tool still fails, the problem is later in the run - send its' -ForegroundColor Green
    Write-Host 'full output, including the line above the error.' -ForegroundColor Green
    exit 0
}
catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { '(none)' }
    $body = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }

    Write-Check 'Result' "HTTP $status" 'bad'
    Write-Host ''
    Write-Host $body -ForegroundColor Red
    Write-Host ''

    if ($body -match 'Authentication information is not given in the correct format') {
        # Reaching here means the token passed every shape check above and Azure
        # still rejected the header - so the value is fine and something between
        # this machine and Azure altered the request. Worth stating plainly,
        # because it rules out the client and points at the network path.
        Write-Host 'Azure rejected the header even though the token checks above all passed.' -ForegroundColor Yellow
        Write-Host 'That points at something rewriting the request in transit - an inspecting' -ForegroundColor Yellow
        Write-Host 'proxy, TLS interception, or a gateway stripping the Authorization header.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Ask whoever runs the network whether management.azure.com is intercepted,' -ForegroundColor Yellow
        Write-Host 'and try the same command from a machine outside that path.' -ForegroundColor Yellow
    }
    elseif ($status -eq 403) {
        Write-Host 'This is a genuine permissions problem. The signed-in identity needs at' -ForegroundColor Yellow
        Write-Host 'least Reader on the resource group, and Contributor to write workbooks.' -ForegroundColor Yellow
    }
    elseif ($status -eq 404) {
        Write-Host 'The resource group or workspace was not found. Check the names, and that' -ForegroundColor Yellow
        Write-Host 'the context is on the right subscription.' -ForegroundColor Yellow
    }

    exit 2
}
