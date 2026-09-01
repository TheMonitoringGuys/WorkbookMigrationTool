#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Core REST API wrapper for the ARM and Log Analytics calls this tool makes.
.DESCRIPTION
    Authenticated, retry-aware, paginated REST calls against Azure Resource
    Manager. Adapted from Sentinel.Api.psm1 in the Sentinel Migration Assistant
    and trimmed to what workbook re-scoping needs: workbooks, workspaces, and the
    Log Analytics query endpoint used by -ValidateQueries.

    The rule, watchlist, and Content Hub URI builders are deliberately absent -
    this tool never touches them.
#>

Import-Module (Join-Path $PSScriptRoot 'WorkbookScope.Common.psm1') -Force -DisableNameChecking

# ── Runtime defaults ──────────────────────────────────────────────────────────
# Retry behaviour is configured once by the orchestrator rather than threaded
# through every call site. Callers may still override per-call.
$script:DefaultRetryCount = 3

function Set-ScopeApiDefault {
    <#
    .SYNOPSIS
        Sets module-wide API defaults from configuration.
    #>
    [CmdletBinding()]
    param([int]$RetryCount = -1)

    if ($RetryCount -ge 0) { $script:DefaultRetryCount = $RetryCount }
}

function Get-ScopeApiDefault {
    <#
    .SYNOPSIS
        Returns the current module-wide API defaults. Primarily for tests.
    #>
    [CmdletBinding()]
    param()
    return [PSCustomObject]@{ RetryCount = $script:DefaultRetryCount }
}

# ── API Versions (documented/stable) ──────────────────────────────────────────
$script:ApiVersions = @{
    workbooks  = '2022-04-01'
    workspaces = '2023-09-01'
    query      = '2017-10-01'
}

function Get-ScopeApiVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Resource)
    if ($script:ApiVersions.ContainsKey($Resource)) {
        return $script:ApiVersions[$Resource]
    }
    throw "Unknown API resource '$Resource'. Known: $($script:ApiVersions.Keys -join ', ')"
}

# ── ARM Endpoint Resolution ───────────────────────────────────────────────────
function Resolve-ArmEndpoint {
    <#
    .SYNOPSIS
        Returns the ARM endpoint for the current Az context.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Commercial', 'Gov')]
        [string]$Cloud = 'Commercial'
    )

    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw "No Az context. Run Connect-AzAccount first." }

    $envName = $ctx.Environment.Name
    $env = Get-AzEnvironment -Name $envName -ErrorAction Stop
    if (-not $env) { throw "Cannot resolve Az environment '$envName'." }

    $endpoint = $env.ResourceManagerUrl.TrimEnd('/')
    Write-Verbose "ARM endpoint resolved: $endpoint (environment: $envName)"
    return $endpoint
}

function Resolve-LogAnalyticsEndpoint {
    <#
    .SYNOPSIS
        Returns the Log Analytics data-plane endpoint for the current Az context.
    .DESCRIPTION
        Only used by -ValidateQueries. Az exposes this as AzureOperationalInsightsEndpoint
        on newer module versions; older ones do not carry it at all, so the
        commercial default is the documented fallback rather than a guess.
    #>
    [CmdletBinding()]
    param()

    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw "No Az context. Run Connect-AzAccount first." }

    $env = Get-AzEnvironment -Name $ctx.Environment.Name -ErrorAction Stop
    $prop = $env.PSObject.Properties['AzureOperationalInsightsEndpoint']
    if ($prop -and $prop.Value) { return ([string]$prop.Value).TrimEnd('/') }

    return 'https://api.loganalytics.io'
}

# ── Token Acquisition ─────────────────────────────────────────────────────────
function Get-ScopeAccessToken {
    <#
    .SYNOPSIS
        Acquires a bearer token for the given audience using the current Az context.
    .DESCRIPTION
        Deliberately paranoid about what it returns, because the failure mode when
        it is not is genuinely hard to diagnose. A malformed header does not come
        back as a clean 401. Azure answers with HTTP 502 and

            Forbidden: Authentication information is not given in the correct
            format. Check the value of Authorization header.

        which reads like a permissions problem, sends people to check RBAC, and is
        actually the client's fault.

        Three ways that happened here:

        - Get-AzAccessToken emitting anything besides the token object - a
          deprecation notice on the output stream, or a second context - makes
          $tokenObj an array. "Bearer $token" then renders every element separated
          by spaces, so the header is nonsense.
        - Az.Accounts 5.x returns the token as a SecureString. Without conversion
          the header reads "Bearer System.Security.SecureString".
        - An expired device-code session can hand back an empty token, giving a
          bare "Bearer " that Azure rejects with the same message.

        Checking the value here turns all three into an error that names the cause
        and the fix, instead of a 502 forty lines later.
    .PARAMETER ResourceUrl
        Audience to request. Defaults to ARM. -ValidateQueries passes the Log
        Analytics endpoint instead, because a token minted for ARM is not
        accepted by the data plane.
    #>
    [CmdletBinding()]
    param([string]$ResourceUrl)

    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw "No Az context. Run Connect-AzAccount first." }

    if (-not $ResourceUrl) {
        $env = Get-AzEnvironment -Name $ctx.Environment.Name -ErrorAction Stop
        $ResourceUrl = $env.ResourceManagerUrl.TrimEnd('/')
    }

    # Take the first object explicitly. If the cmdlet wrote anything else to the
    # output stream, the property access below would otherwise yield an array.
    $tokenObj = @(Get-AzAccessToken -ResourceUrl $ResourceUrl -ErrorAction Stop)[0]
    if (-not $tokenObj) {
        throw "Get-AzAccessToken returned nothing for '$ResourceUrl'. Sign in again: Connect-AzAccount"
    }

    $raw = $tokenObj.Token
    if ($raw -is [securestring]) {
        $raw = $raw | ConvertFrom-SecureString -AsPlainText
    }

    # Guard against a value that is an array even after the coercion above.
    if ($raw -is [System.Collections.IEnumerable] -and $raw -isnot [string]) {
        $raw = @($raw)[0]
    }

    $token = ([string]$raw).Trim()
    Assert-ScopeTokenUsable -Token $token -ResourceUrl $ResourceUrl
    return $token
}

function Assert-ScopeTokenUsable {
    <#
    .SYNOPSIS
        Fails loudly when a token could not produce a valid Authorization header.
    .DESCRIPTION
        Every message names what to do next. The whole point is to stop a bad
        header reaching Azure, which reports it as HTTP 502 with a Forbidden
        message about header format - wording that sends operators to check RBAC
        for a problem that has nothing to do with permissions.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Token,
        [string]$ResourceUrl
    )

    $reconnect = "Sign in again, then re-run. In tenants that require it: Connect-AzAccount -UseDeviceAuth"

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw "No access token was returned for '$ResourceUrl'. The Azure session has probably expired. $reconnect"
    }

    if ($Token -eq 'System.Security.SecureString') {
        throw "The access token for '$ResourceUrl' came back as an unconverted SecureString. This build of Az.Accounts is not supported; update it: Update-Module Az.Accounts"
    }

    # Whitespace inside the value means it is not one token - most often several
    # joined together, which is what an unexpected extra output object produces.
    if ($Token -match '\s') {
        throw "The access token for '$ResourceUrl' contains whitespace, so the Authorization header would be malformed. This usually means Get-AzAccessToken returned more than one object. Check for multiple Azure contexts with Get-AzContext -ListAvailable, select one with Set-AzContext, and re-run."
    }

    # A JWT is three base64url segments separated by dots. Anything else would be
    # rejected by Azure with a message that does not mention the token at all.
    if ($Token -notmatch '^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]*$') {
        $preview = if ($Token.Length -gt 12) { $Token.Substring(0, 12) } else { $Token }
        throw "The value returned for '$ResourceUrl' is not a bearer token (starts '$preview...', length $($Token.Length)). $reconnect"
    }
}

# ── Core REST Invocation ──────────────────────────────────────────────────────
function Invoke-ScopeApi {
    <#
    .SYNOPSIS
        Authenticated ARM REST call with retry, backoff, and dry-run support.
    .PARAMETER Uri
        Full URI including api-version query parameter.
    .PARAMETER Method
        HTTP method.
    .PARAMETER Body
        Request body, serialised to JSON when not already a string.
    .PARAMETER DryRun
        When set, write methods are skipped and a simulated result is returned.
    .PARAMETER ResourceUrl
        Token audience override, for data-plane calls.
    .PARAMETER RetryCount
        Retries on transient / throttle errors. Defaults to the module-wide value.
    .PARAMETER ThrottleDelayMs
        Base delay between requests in milliseconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'PUT', 'POST', 'DELETE', 'PATCH')]
        [string]$Method = 'GET',
        [object]$Body,
        [switch]$DryRun,
        [string]$ResourceUrl,
        [int]$RetryCount = -1,
        [int]$ThrottleDelayMs = 100
    )

    # -1 means "not specified by the caller", so the configured default applies.
    if ($RetryCount -lt 0) { $RetryCount = $script:DefaultRetryCount }

    $token = Get-ScopeAccessToken -ResourceUrl $ResourceUrl
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    $writeMethods = @('PUT', 'POST', 'DELETE', 'PATCH')
    # POST is how the Log Analytics query endpoint reads data, so a dry run must
    # not skip it - it changes nothing. Only ARM writes are suppressed.
    $isArmWrite = $Method -in $writeMethods -and -not $ResourceUrl
    if ($DryRun -and $isArmWrite) {
        Write-Verbose "[DRY-RUN] Skipping $Method $Uri"
        return [PSCustomObject]@{
            DryRun    = $true
            Method    = $Method
            Uri       = $Uri
            Body      = $Body
            Simulated = $true
        }
    }

    if ($ThrottleDelayMs -gt 0) {
        Start-Sleep -Milliseconds $ThrottleDelayMs
    }

    $bodyJson = $null
    if ($Body) {
        if ($Body -is [string]) { $bodyJson = $Body }
        else { $bodyJson = $Body | ConvertTo-Json -Depth 100 -Compress }
    }

    $attempt = 0
    $maxAttempts = $RetryCount + 1

    while ($attempt -lt $maxAttempts) {
        $attempt++
        try {
            $params = @{
                Uri     = $Uri
                Method  = $Method
                Headers = $headers
            }
            if ($bodyJson) { $params['Body'] = $bodyJson }

            return Invoke-RestMethod @params -ErrorAction Stop
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            $detail = Format-ApiErrorDetail -ErrorRecord $_

            # Azure reports a malformed Authorization header as HTTP 502 with a
            # Forbidden message about header format. It is in the retryable set by
            # status code, but it is entirely deterministic - the same bad header
            # fails identically every time - so retrying only adds ~14s of backoff
            # before the same failure. Catch it by its wording and stop.
            if ($detail -and $detail -match 'Authentication information is not given in the correct format') {
                throw "HTTP $statusCode on $Method $Uri - Azure rejected the Authorization header as malformed. Despite the wording this is not a permissions problem: the request never reached the point of checking access. The token this tool sent was not usable. Sign in again and re-run. In tenants that require it: Connect-AzAccount -UseDeviceAuth. If it recurs, check for multiple Azure contexts with Get-AzContext -ListAvailable."
            }

            $retryable = $statusCode -in @(429, 500, 502, 503, 504)

            if ($retryable -and $attempt -lt $maxAttempts) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                if ($statusCode -eq 429 -and $_.Exception.Response.Headers) {
                    $retryAfter = $_.Exception.Response.Headers | Where-Object { $_.Key -eq 'Retry-After' } | Select-Object -ExpandProperty Value -First 1
                    if ($retryAfter) { $backoff = [math]::Max($backoff, [int]$retryAfter * 1000) }
                }
                Write-Warning "Request failed (HTTP $statusCode), retrying in $($backoff/1000)s (attempt $attempt/$maxAttempts)..."
                Start-Sleep -Milliseconds $backoff
                # Refresh the token in case it expired during backoff.
                $token = Get-ScopeAccessToken -ResourceUrl $ResourceUrl
                $headers['Authorization'] = "Bearer $token"
            }
            else {
                # Enhance the error with readable ARM detail, but preserve 404s
                # as-is because callers catch those for existence checks.
                if ($statusCode -and $statusCode -ne 404 -and $detail) {
                    throw "HTTP $statusCode on $Method $Uri - $detail"
                }
                throw
            }
        }
    }
}

# ── Paginated List ────────────────────────────────────────────────────────────
function Invoke-ScopeApiList {
    <#
    .SYNOPSIS
        GET with automatic nextLink pagination. Returns all items across pages.
    .DESCRIPTION
        Bounded by MaxRecords and MaxPages, and guarded against a self-referential
        nextLink, so a large or misbehaving collection cannot hang the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$ThrottleDelayMs = 100,
        [int]$MaxRecords = 50000,
        [int]$MaxPages = 1000
    )

    $allItems = [System.Collections.Generic.List[object]]::new()
    $currentUri = $Uri
    $pages = 0
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    while ($currentUri) {
        # A nextLink pointing back at a page already fetched would loop forever.
        if (-not $seen.Add([string]$currentUri)) {
            Write-Warning "Repeated nextLink detected; stopping pagination for: $Uri"
            break
        }

        $response = Invoke-ScopeApi -Uri $currentUri -Method GET -ThrottleDelayMs $ThrottleDelayMs
        $pages++
        if ($response.value) {
            $allItems.AddRange(@($response.value))
        }

        if ($MaxRecords -gt 0 -and $allItems.Count -ge $MaxRecords) {
            while ($allItems.Count -gt $MaxRecords) { $allItems.RemoveAt($allItems.Count - 1) }
            Write-Warning "Reached MaxRecords ($MaxRecords); results truncated for: $Uri"
            break
        }
        if ($pages -ge $MaxPages) {
            Write-Warning "Reached MaxPages ($MaxPages); results truncated for: $Uri"
            break
        }

        $currentUri = $response.nextLink
    }

    return $allItems.ToArray()
}

# ── URI Builders ──────────────────────────────────────────────────────────────
function Get-WorkspaceResourceId {
    <#
    .SYNOPSIS
        Builds the bare workspace resource ID - no ARM endpoint, no api-version.
    .DESCRIPTION
        This is the string that goes into crossComponentResources and
        fallbackResourceIds, so it must be the resource ID and nothing else.
        Get-ScopeWorkspaceUri returns the callable ARM URL instead; the two are
        not interchangeable and conflating them silently produces a workbook that
        renders no data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkspaceName
    )
    return "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"
}

function Get-ScopeWorkspaceUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkspaceName
    )
    $id = Get-WorkspaceResourceId -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    return "$ArmEndpoint$id"
}

function Get-WorkspaceUriWithVersion {
    <#
    .SYNOPSIS
        Callable workspace GET URI, used to confirm existence and read location.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceUri)
    $v = Get-ScopeApiVersion -Resource 'workspaces'
    return "$WorkspaceUri`?api-version=$v"
}

function Get-WorkbooksUri {
    <#
    .SYNOPSIS
        Lists Sentinel workbooks in a resource group, optionally scoped to one workspace.
    .PARAMETER SourceId
        The workspace resource ID a workbook is bound to. Passing it keeps the
        list to workbooks belonging to that workspace, which matters when source
        and destination share a resource group.
    .PARAMETER ExcludeContent
        Omits canFetchContent, so the response carries metadata only.

        canFetchContent=true returns the full serializedData of every workbook in
        a single response. In this tool's own corpus one workbook serialises to
        807 KB, so sixteen of them is a multi-megabyte body from one GET. That is
        fine against ARM directly and is what the Sentinel Migration Assistant
        does, but the migration assistant reads the *source*, whereas this tool
        reads the *destination* - which has accumulated every migrated workbook.
        Same request, substantially more payload.

        A large response is a plausible way to earn a 502 from an intermediary,
        so the caller can list cheaply with this switch and then fetch each
        workbook's content on its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [string]$SourceId,
        [switch]$ExcludeContent
    )
    $v = Get-ScopeApiVersion -Resource 'workbooks'
    $uri = "$ArmEndpoint/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/workbooks?category=sentinel&api-version=$v"
    if (-not $ExcludeContent) {
        $uri = $uri -replace '\?category=sentinel', '?category=sentinel&canFetchContent=true'
    }
    if ($SourceId) {
        $uri += "&sourceId=$([Uri]::EscapeDataString($SourceId))"
    }
    return $uri
}

function Get-WorkbookUri {
    <#
    .SYNOPSIS
        URI for a single workbook resource.
    .PARAMETER IncludeContent
        Adds canFetchContent, without which a GET returns the workbook's metadata
        and an empty serializedData. Verified against ARM: the same workbook
        returns 0 characters of content without it and 1548 with it.

        Not set by default, because the write path sends content rather than
        asking for it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkbookId,
        [switch]$IncludeContent
    )
    $v = Get-ScopeApiVersion -Resource 'workbooks'
    $uri = "$ArmEndpoint/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/workbooks/$($WorkbookId)?api-version=$v"
    if ($IncludeContent) { $uri += '&canFetchContent=true' }
    return $uri
}

function Get-LogAnalyticsQueryUri {
    <#
    .SYNOPSIS
        Data-plane query URI for a workspace, used only by -ValidateQueries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogAnalyticsEndpoint,
        [Parameter(Mandatory)][string]$WorkspaceId
    )
    $v = Get-ScopeApiVersion -Resource 'query'
    return "$LogAnalyticsEndpoint/v1/workspaces/$WorkspaceId/query?api-version=$v"
}

Export-ModuleMember -Function @(
    'Get-ScopeApiVersion'
    'Set-ScopeApiDefault'
    'Get-ScopeApiDefault'
    'Resolve-ArmEndpoint'
    'Resolve-LogAnalyticsEndpoint'
    'Get-ScopeAccessToken'
    'Assert-ScopeTokenUsable'
    'Invoke-ScopeApi'
    'Invoke-ScopeApiList'
    'Get-WorkspaceResourceId'
    'Get-ScopeWorkspaceUri'
    'Get-WorkspaceUriWithVersion'
    'Get-WorkbooksUri'
    'Get-WorkbookUri'
    'Get-LogAnalyticsQueryUri'
)
