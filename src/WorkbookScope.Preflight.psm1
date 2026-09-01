Import-Module (Join-Path $PSScriptRoot 'WorkbookScope.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'WorkbookScope.Api.psm1') -Force -DisableNameChecking

function Test-ScopeModulePresent {
    <#
    .SYNOPSIS
        Returns the highest installed version of a module, or null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $found = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($found) { return $found.Version }
    return $null
}

function Get-ScopeHttpStatusFromError {
    <#
    .SYNOPSIS
        Extracts an HTTP status code from an ARM failure when one is available.
    .DESCRIPTION
        Invoke-ScopeApi preserves raw 404 exceptions so callers can branch on the
        response. For other statuses it throws a clearer string that starts with
        "HTTP nnn"; this helper handles both forms.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ErrorRecord)

    $status = Get-ApiErrorStatusCode -ErrorRecord $ErrorRecord
    if ($status) { return $status }

    $detail = Format-ApiErrorDetail -ErrorRecord $ErrorRecord
    if ($detail -match '\bHTTP\s+(\d{3})\b') { return [int]$matches[1] }
    return $null
}

function Assert-ScopePrerequisite {
    <#
    .SYNOPSIS
        Verifies this PowerShell session can run workbook scoping.
    .DESCRIPTION
        These checks fail before any workbook is read or written. The messages
        name the exact command to run so operators do not have to infer whether a
        failure is a missing module, a stale shell, or a missing Azure sign-in.
    #>
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7.0 or later is required (found $($PSVersionTable.PSVersion)). Start this tool with: pwsh"
    }

    $azAccountsVersion = Test-ScopeModulePresent -Name 'Az.Accounts'
    if (-not $azAccountsVersion) {
        throw "Missing required module 'Az.Accounts'. Install it with: Install-Module -Name Az.Accounts -Scope CurrentUser"
    }

    if (-not (Get-Command Get-AzContext -ErrorAction SilentlyContinue)) {
        throw "Az.Accounts is installed but not loaded. Load it with: Import-Module Az.Accounts"
    }

    try {
        $context = Get-AzContext -ErrorAction Stop
    }
    catch {
        throw "No live Azure context. Sign in with: Connect-AzAccount"
    }

    if (-not $context) {
        throw "No live Azure context. Sign in with: Connect-AzAccount"
    }

    # No return value on purpose. This is an assertion: it either throws or says
    # nothing. Returning $true printed a bare "True" into the operator's console
    # between the prerequisite and ARM endpoint lines.
}

function Test-WorkspaceReachable {
    <#
    .SYNOPSIS
        Confirms a Log Analytics workspace can be read through ARM.
    .DESCRIPTION
        The returned CustomerId is the workspace GUID used later by the Log
        Analytics data-plane query API. The ARM resource ID alone is not enough
        for that endpoint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [int]$ThrottleDelayMs = 100
    )

    $resourceId = Get-WorkspaceResourceId -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    $workspaceUri = Get-ScopeWorkspaceUri -ArmEndpoint $ArmEndpoint -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    $uri = Get-WorkspaceUriWithVersion -WorkspaceUri $workspaceUri

    try {
        $workspace = Invoke-ScopeApi -Uri $uri -Method GET -ThrottleDelayMs $ThrottleDelayMs
        $customerId = $null
        if ($workspace.properties) { $customerId = [string]$workspace.properties.customerId }

        return [PSCustomObject]@{
            Reachable  = $true
            Location   = [string]$workspace.location
            CustomerId = $customerId
            ResourceId = if ($workspace.id) { [string]$workspace.id } else { $resourceId }
            Message    = "Workspace '$WorkspaceName' is reachable."
        }
    }
    catch {
        $status = Get-ScopeHttpStatusFromError -ErrorRecord $_
        $detail = Format-ApiErrorDetail -ErrorRecord $_

        $message = $null
        if ($status -eq 404) {
            $message = "Workspace '$WorkspaceName' was not found. Check subscription, resource group and workspace name."
        }
        elseif ($status -eq 403) {
            $message = "Access denied reading workspace '$WorkspaceName'. The signed-in identity needs at least Reader on the workspace. ($detail)"
        }
        else {
            $message = "Could not read workspace '$WorkspaceName': $detail"
        }

        return [PSCustomObject]@{
            Reachable  = $false
            Location   = $null
            CustomerId = $null
            ResourceId = $resourceId
            Message    = $message
        }
    }
}

function Test-DestinationWritable {
    <#
    .SYNOPSIS
        Reports whether destination workbook write access can be proven.
    .DESCRIPTION
        This tool must not create and delete a workbook just to test permission.
        The available shared API module does not expose a versioned permissions
        URI, and this code deliberately does not invent API versions. Unknown is
        therefore safer than a false negative.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [int]$ThrottleDelayMs = 100
    )

    $null = $ArmEndpoint
    $null = $SubscriptionId
    $null = $ResourceGroupName
    $null = $ThrottleDelayMs

    return [PSCustomObject]@{
        Writable = 'Unknown'
        Message  = "Destination workbook write access was not probed. No reliable non-destructive workbook write check is available through this tool's shared API wrapper; the run may still fail when it writes if the identity lacks Microsoft.Insights/workbooks/write on the destination resource group."
    }
}

function Invoke-ScopePreflight {
    <#
    .SYNOPSIS
        Runs the workbook scoping preflight checks.
    .DESCRIPTION
        Reachability failures are blocking when applying scope, because a workbook
        cannot be pointed at a workspace that is not there. Write permission is
        blocking only when it is known to be absent; an unknown non-destructive
        probe is reported as a warning so operators can decide from role
        assignments.
    .PARAMETER IsRevert
        Relaxes the source workspace check. Reverting is what an operator does
        *because* the source workspace is going away, so its absence is the
        expected state rather than an error - and revert needs nothing from it:
        the resource ID is built from configuration, and the snapshot and
        manifest tiers never call the source at all.

        Without this, the recovery path was blocked at exactly the moment it was
        needed. A run against a deleted source exited 2, while the same run with
        -SkipPreflight reverted every workbook successfully - so preflight was
        refusing work that would have succeeded, and the operator had to reach
        for a flag documented as "not recommended" that also disables the
        destination checks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArmEndpoint,
        [Parameter(Mandatory)][object]$SourceConfig,
        [Parameter(Mandatory)][object]$DestinationConfig,
        [int]$ThrottleDelayMs = 100,
        [switch]$IsRevert
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $source = Test-WorkspaceReachable -ArmEndpoint $ArmEndpoint `
        -SubscriptionId $SourceConfig.SubscriptionId `
        -ResourceGroupName $SourceConfig.ResourceGroupName `
        -WorkspaceName $SourceConfig.WorkspaceName `
        -ThrottleDelayMs $ThrottleDelayMs

    $destination = Test-WorkspaceReachable -ArmEndpoint $ArmEndpoint `
        -SubscriptionId $DestinationConfig.SubscriptionId `
        -ResourceGroupName $DestinationConfig.ResourceGroupName `
        -WorkspaceName $DestinationConfig.WorkspaceName `
        -ThrottleDelayMs $ThrottleDelayMs

    if (-not $source.Reachable) {
        if ($IsRevert) {
            $warnings.Add("Source workspace is not reachable, which is expected when reverting after it has been decommissioned. Revert does not read it. $($source.Message)")
        }
        else {
            $errors.Add("Source workspace is not reachable. $($source.Message)")
        }
    }
    # The destination holds the workbooks being read and written, so it is
    # blocking in every mode.
    if (-not $destination.Reachable) { $errors.Add("Destination workspace is not reachable. $($destination.Message)") }

    $writable = Test-DestinationWritable -ArmEndpoint $ArmEndpoint `
        -SubscriptionId $DestinationConfig.SubscriptionId `
        -ResourceGroupName $DestinationConfig.ResourceGroupName `
        -ThrottleDelayMs $ThrottleDelayMs

    if ($writable.Writable -eq 'No') {
        $errors.Add("The signed-in identity cannot write workbooks to the destination resource group. $($writable.Message)")
    }
    elseif ($writable.Writable -eq 'Unknown') {
        $warnings.Add($writable.Message)
    }

    $crossSubscription = -not [string]::Equals(
        [string]$SourceConfig.SubscriptionId,
        [string]$DestinationConfig.SubscriptionId,
        [System.StringComparison]::OrdinalIgnoreCase)

    $crossRegion = $false
    if ($source.Location -and $destination.Location) {
        $crossRegion = -not [string]::Equals(
            [string]$source.Location,
            [string]$destination.Location,
            [System.StringComparison]::OrdinalIgnoreCase)
    }

    if ($crossSubscription) {
        $warnings.Add("Source and destination are in different subscriptions. Workbook resource-picker parameters are scoped to a single subscription, so the source workspace will not appear in the picker until this tool widens it; the engine handles that update.")
    }

    if ($crossRegion) {
        $warnings.Add("Source and destination are in different regions. Cross-resource queries must serialise and move intermediate data between regions, so dashboards will be measurably slower.")
    }

    $warnings.Add("Anyone viewing these workbooks needs Microsoft.OperationalInsights/workspaces/query/*/read (Log Analytics Reader) on both workspaces. Without that role on the source workspace, the workbook update succeeds but the workbook renders empty.")

    return [PSCustomObject]@{
        Passed            = ($errors.Count -eq 0)
        Source            = $source
        Destination       = $destination
        Warnings          = $warnings.ToArray()
        Errors            = $errors.ToArray()
        CrossSubscription = $crossSubscription
        CrossRegion       = $crossRegion
    }
}

Export-ModuleMember -Function @(
    'Assert-ScopePrerequisite'
    'Test-WorkspaceReachable'
    'Invoke-ScopePreflight'
    'Test-DestinationWritable'
)
