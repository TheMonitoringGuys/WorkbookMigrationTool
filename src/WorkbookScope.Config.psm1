<#
.SYNOPSIS
    Configuration loading and merging for the Workbook Scope Assistant.
.DESCRIPTION
    Loads JSON or YAML config files and merges them with command-line parameter
    overrides. JSON needs no third-party module; YAML requires powershell-yaml.

    The schema deliberately accepts both 'destination' and 'target' for the second
    workspace. This tool's own vocabulary is source/destination, but the config
    file a customer already wrote for the Sentinel Migration Assistant says
    'target' - and being able to point this tool straight at that file, unchanged,
    removes an entire class of transcription mistake in the workspace IDs.
#>

function Test-ConfigIsJson {
    <#
    .SYNOPSIS
        Decides whether a config file should be parsed as JSON.
    .DESCRIPTION
        Extension first, then content sniffing, so a JSON document saved with a
        .yml extension still parses. (JSON is a subset of YAML, but the reverse
        is not true, so guessing wrong towards JSON is the safe direction.)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Content = ''
    )

    if ([System.IO.Path]::GetExtension($Path) -ieq '.json') { return $true }
    return ($Content.TrimStart() -match '^\{')
}

function Import-YamlModule {
    <#
    .SYNOPSIS
        Imports powershell-yaml, installing it only when explicitly permitted.
    .PARAMETER NoAutoInstall
        Suppresses the install and throws with instructions instead.
    #>
    [CmdletBinding()]
    param([switch]$NoAutoInstall)

    if (Get-Module -Name 'powershell-yaml' -ErrorAction SilentlyContinue) { return }

    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction SilentlyContinue)) {
        if ($NoAutoInstall) {
            throw "The 'powershell-yaml' module is required to read a YAML config file.`n" +
            "  Install it:   Install-Module -Name powershell-yaml -Scope CurrentUser`n" +
            "  Or avoid it:  supply the same settings in a .json config file, which needs no extra module."
        }
        Write-Host "  Installing powershell-yaml (CurrentUser scope)..." -ForegroundColor Yellow
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module powershell-yaml -ErrorAction Stop
}

function Read-ScopeConfig {
    <#
    .SYNOPSIS
        Loads a JSON or YAML config file and returns a normalised configuration object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$NoAutoInstall
    )

    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }

    $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Configuration file is empty: $Path"
    }

    if (Test-ConfigIsJson -Path $Path -Content $raw) {
        try {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Failed to parse JSON config '$Path': $($_.Exception.Message)"
        }
    }
    else {
        Import-YamlModule -NoAutoInstall:$NoAutoInstall
        try {
            $parsed = ConvertFrom-Yaml -Yaml $raw -ErrorAction Stop
        }
        catch {
            throw "Failed to parse YAML config '$Path': $($_.Exception.Message)"
        }
    }

    return ConvertTo-NormalizedConfig -RawConfig $parsed
}

function Get-ConfigValue {
    <#
    .SYNOPSIS
        Reads a key from either a hashtable (YAML) or a PSCustomObject (JSON).
    .DESCRIPTION
        ConvertFrom-Yaml returns hashtables and ConvertFrom-Json returns
        PSCustomObjects. Property access works on one and not the other, so
        every read goes through here rather than assuming a shape.
    #>
    [CmdletBinding()]
    param(
        [object]$Node,
        [Parameter(Mandatory)][string]$Key
    )

    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains($Key)) { return $Node[$Key] }
        return $null
    }
    $prop = $Node.PSObject.Properties[$Key]
    if ($prop) { return $prop.Value }
    return $null
}

function ConvertTo-NormalizedConfig {
    <#
    .SYNOPSIS
        Validates and normalises raw config into a typed config object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$RawConfig)

    $cfg = [PSCustomObject]@{
        Source      = [PSCustomObject]@{
            SubscriptionId    = $null
            ResourceGroupName = $null
            WorkspaceName     = $null
        }
        Destination = [PSCustomObject]@{
            SubscriptionId    = $null
            ResourceGroupName = $null
            WorkspaceName     = $null
        }
        Options     = [PSCustomObject]@{
            DryRun              = $true
            Cloud               = 'Commercial'
            ScopeMode           = 'Literal'
            Revert              = $false
            ValidateQueries     = $false
            IncludeAllWorkbooks = $false
            WorkbookFilter      = $null
            RetryCount          = 3
            ThrottleMs          = 100
            LookbackDays        = 7
        }
    }

    $src = Get-ConfigValue -Node $RawConfig -Key 'source'
    if ($src) {
        $v = Get-ConfigValue -Node $src -Key 'subscriptionId';    if ($v) { $cfg.Source.SubscriptionId = $v }
        $v = Get-ConfigValue -Node $src -Key 'resourceGroupName'; if ($v) { $cfg.Source.ResourceGroupName = $v }
        $v = Get-ConfigValue -Node $src -Key 'workspaceName';     if ($v) { $cfg.Source.WorkspaceName = $v }
    }

    # 'destination' is this tool's word; 'target' is the migration tool's. Accept
    # both so an existing migration config file works here without edits.
    $dst = Get-ConfigValue -Node $RawConfig -Key 'destination'
    if (-not $dst) { $dst = Get-ConfigValue -Node $RawConfig -Key 'target' }
    if ($dst) {
        $v = Get-ConfigValue -Node $dst -Key 'subscriptionId';    if ($v) { $cfg.Destination.SubscriptionId = $v }
        $v = Get-ConfigValue -Node $dst -Key 'resourceGroupName'; if ($v) { $cfg.Destination.ResourceGroupName = $v }
        $v = Get-ConfigValue -Node $dst -Key 'workspaceName';     if ($v) { $cfg.Destination.WorkspaceName = $v }
    }

    $o = Get-ConfigValue -Node $RawConfig -Key 'options'
    if ($o) {
        $v = Get-ConfigValue -Node $o -Key 'dryRun';              if ($null -ne $v) { $cfg.Options.DryRun = [bool]$v }
        $v = Get-ConfigValue -Node $o -Key 'cloud';               if ($null -ne $v) { $cfg.Options.Cloud = $v }
        $v = Get-ConfigValue -Node $o -Key 'scopeMode';           if ($null -ne $v) { $cfg.Options.ScopeMode = $v }
        $v = Get-ConfigValue -Node $o -Key 'revert';              if ($null -ne $v) { $cfg.Options.Revert = [bool]$v }
        $v = Get-ConfigValue -Node $o -Key 'validateQueries';     if ($null -ne $v) { $cfg.Options.ValidateQueries = [bool]$v }
        $v = Get-ConfigValue -Node $o -Key 'includeAllWorkbooks'; if ($null -ne $v) { $cfg.Options.IncludeAllWorkbooks = [bool]$v }
        $v = Get-ConfigValue -Node $o -Key 'workbookFilter';      if ($null -ne $v) { $cfg.Options.WorkbookFilter = $v }
        $v = Get-ConfigValue -Node $o -Key 'retryCount';          if ($null -ne $v) { $cfg.Options.RetryCount = [int]$v }
        $v = Get-ConfigValue -Node $o -Key 'throttleMs';          if ($null -ne $v) { $cfg.Options.ThrottleMs = [int]$v }
        $v = Get-ConfigValue -Node $o -Key 'lookbackDays';        if ($null -ne $v) { $cfg.Options.LookbackDays = [int]$v }
    }

    return $cfg
}

function Merge-ParameterOverrides {
    <#
    .SYNOPSIS
        Merges CLI parameter overrides onto a config object. CLI params win.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [hashtable]$Overrides
    )

    foreach ($key in $Overrides.Keys) {
        $val = $Overrides[$key]
        if ($null -eq $val) { continue }
        # An unbound [string] parameter arrives as '' rather than $null. Treating
        # that as an override would blank a value the config file supplied, so
        # empty strings are ignored here as well. Callers that genuinely want to
        # clear a value should omit the key entirely.
        if ($val -is [string] -and [string]::IsNullOrEmpty($val)) { continue }

        switch ($key) {
            'SourceSubscriptionId'      { $Config.Source.SubscriptionId = $val }
            'SourceResourceGroup'       { $Config.Source.ResourceGroupName = $val }
            'SourceWorkspace'           { $Config.Source.WorkspaceName = $val }
            'DestinationSubscriptionId' { $Config.Destination.SubscriptionId = $val }
            'DestinationResourceGroup'  { $Config.Destination.ResourceGroupName = $val }
            'DestinationWorkspace'      { $Config.Destination.WorkspaceName = $val }
            'DryRun'                    { $Config.Options.DryRun = [bool]$val }
            'Cloud'                     { $Config.Options.Cloud = $val }
            'ScopeMode'                 { $Config.Options.ScopeMode = $val }
            'Revert'                    { $Config.Options.Revert = [bool]$val }
            'ValidateQueries'           { $Config.Options.ValidateQueries = [bool]$val }
            'IncludeAllWorkbooks'       { $Config.Options.IncludeAllWorkbooks = [bool]$val }
            'WorkbookFilter'            { $Config.Options.WorkbookFilter = $val }
            'RetryCount'                { $Config.Options.RetryCount = [int]$val }
            'ThrottleMs'                { $Config.Options.ThrottleMs = [int]$val }
            'LookbackDays'              { $Config.Options.LookbackDays = [int]$val }
        }
    }

    return $Config
}

function Assert-ConfigValid {
    <#
    .SYNOPSIS
        Validates that required config fields are present and coherent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Config)

    $errors = @()
    if (-not $Config.Source.SubscriptionId)         { $errors += "source.subscriptionId is required" }
    if (-not $Config.Source.ResourceGroupName)      { $errors += "source.resourceGroupName is required" }
    if (-not $Config.Source.WorkspaceName)          { $errors += "source.workspaceName is required" }
    if (-not $Config.Destination.SubscriptionId)    { $errors += "destination.subscriptionId is required" }
    if (-not $Config.Destination.ResourceGroupName) { $errors += "destination.resourceGroupName is required" }
    if (-not $Config.Destination.WorkspaceName)     { $errors += "destination.workspaceName is required" }

    if ($Config.Options.Cloud -notin @('Commercial', 'Gov')) {
        $errors += "options.cloud must be 'Commercial' or 'Gov'"
    }

    if ($Config.Options.ScopeMode -notin @('SelfHealing', 'Literal')) {
        $errors += "options.scopeMode must be 'SelfHealing' or 'Literal' (got '$($Config.Options.ScopeMode)')"
    }

    if ($Config.Options.RetryCount -lt 0 -or $Config.Options.RetryCount -gt 10) {
        $errors += "options.retryCount must be between 0 and 10 (got $($Config.Options.RetryCount))"
    }

    if ($Config.Options.ThrottleMs -lt 0 -or $Config.Options.ThrottleMs -gt 60000) {
        $errors += "options.throttleMs must be between 0 and 60000 (got $($Config.Options.ThrottleMs))"
    }

    if ($Config.Options.LookbackDays -lt 1 -or $Config.Options.LookbackDays -gt 365) {
        $errors += "options.lookbackDays must be between 1 and 365 (got $($Config.Options.LookbackDays))"
    }

    # Scoping a workspace to itself is a no-op that still rewrites every workbook.
    $same = (
        $Config.Source.SubscriptionId -eq $Config.Destination.SubscriptionId -and
        $Config.Source.ResourceGroupName -eq $Config.Destination.ResourceGroupName -and
        $Config.Source.WorkspaceName -eq $Config.Destination.WorkspaceName
    )
    if ($same -and $Config.Source.WorkspaceName) {
        $errors += "source and destination refer to the same workspace ('$($Config.Source.WorkspaceName)'). Dual scoping requires two different workspaces."
    }

    if ($errors.Count -gt 0) {
        throw "Configuration validation failed:`n  - $($errors -join "`n  - ")"
    }
}

Export-ModuleMember -Function @(
    'Read-ScopeConfig'
    'ConvertTo-NormalizedConfig'
    'Merge-ParameterOverrides'
    'Assert-ConfigValid'
    'Test-ConfigIsJson'
    'Get-ConfigValue'
    'Import-YamlModule'
)
