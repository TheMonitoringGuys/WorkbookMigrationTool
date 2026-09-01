<#
.SYNOPSIS
    The scope transform: reads a workbook's serialized definition, points its
    Log Analytics queries at both workspaces, and puts them back.
.DESCRIPTION
    This module is deliberately network-free. Everything here operates on parsed
    JSON, which is what makes the whole 500-query corpus testable offline.

    A workbook's content lives in properties.serializedData as a JSON *string*.
    Inside it, every query item may carry a 'crossComponentResources' array
    naming the resources it reads. The Workbooks engine unions across whatever
    that array names, so dual-scoping is a matter of putting both workspace
    resource IDs in it. No KQL is ever parsed or rewritten.

    Three shapes turn up in real workbooks, and each needs different handling:

      A. No crossComponentResources at all. The query inherits the workbook's
         default resource. Add the array.
      B. A literal token - 'value::selected' or 'value::all'. Replace it, keeping
         the original so revert is exact.
      C. A parameter reference such as '{Workspace}'. Literal mode leaves the
         query alone and patches the *parameter* instead; touching the query
         would break the link to the picker the user sees in the UI.

     Self-healing mode keeps the customer's picker untouched. It appends the
     injected WBScopeSource reference beside the existing picker reference in
     each query. ParametersPatched counts parameters the tool rewrote; ScopedViaPicker
     counts queries that kept their own picker and received that extra reference.

    Round-trip fidelity was verified against 16 real workbooks: parsing with
    -AsHashtable and re-serialising is lossless apart from a trailing CRLF that
    sits outside the JSON document.
#>

Import-Module (Join-Path $PSScriptRoot 'WorkbookScope.Common.psm1') -Force -DisableNameChecking

$script:ManifestKey = '$dualScope'
$script:ManifestVersion = 2
$script:LaResourceType = 'microsoft.operationalinsights/workspaces'
$script:ArgResourceType = 'microsoft.resourcegraph/resources'
$script:ToolName = 'Sentinel-Workbook-Scope-Assistant'
$script:ScopeParameterName = 'WBScopeSource'

# ── Self-healing scope parameter ──────────────────────────────────────────────
function Get-ScopeParameterName {
    <#
    .SYNOPSIS
        Returns a scope parameter name that does not collide with an existing one.
    .DESCRIPTION
        A workbook that already defines a parameter of this name would otherwise
        have it silently redefined, changing behaviour the customer wrote. The
        corpus has no collisions today, but a numeric suffix costs nothing and
        removes the failure mode entirely.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Root)

    $taken = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @(Get-WorkbookNode -Root $Root)) {
        if (-not (Test-IsParameterNode -Path $entry.Path)) { continue }
        $n = [string]$entry.Node['name']
        if ($n) { [void]$taken.Add($n) }
    }

    if (-not $taken.Contains($script:ScopeParameterName)) { return $script:ScopeParameterName }
    for ($i = 2; $i -lt 100; $i++) {
        $candidate = "$($script:ScopeParameterName)$i"
        if (-not $taken.Contains($candidate)) { return $candidate }
    }
    throw "Could not find a free name for the scope parameter."
}

function New-ScopeParameterItem {
    <#
    .SYNOPSIS
        Builds the hidden parameter that makes dual scope survive deletion.
    .DESCRIPTION
        A resource picker backed by Azure Resource Graph, filtered to exactly one
        workspace. Resource Graph is an inventory of live resources, so once the
        source workspace is deleted the query returns no rows, the parameter
        resolves to empty, and every reference to it drops out of the scope lists
        that mention it. The destination literal beside it keeps the workbook
        rendering.

        Three flags carry the design, and each matters:

        - isGlobal makes the parameter visible to every step. The corpus nests
          parameter blocks four levels deep, and a non-global parameter is only
          visible inside its own group, so without this most queries could not
          resolve it.
        - isHiddenWhenLocked keeps it out of the viewer's face. It is still
          visible when editing the workbook, which is where someone would want to
          find it.
        - isRequired is deliberately ABSENT. A required picker with no results
          blocks every query that depends on it, which would turn the graceful
          degradation this whole design exists for into a hard failure.

        The id is derived from the source workspace rather than random, so
        re-running produces a byte-identical parameter and the run stays
        idempotent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParameterName,
        [Parameter(Mandatory)][string]$SourceWorkspaceId,
        [string]$SourceSubscriptionId
    )

    $md5 = [System.Security.Cryptography.MD5]::Create()
    $seed = "wbscope-param:$ParameterName`:$SourceWorkspaceId"
    $paramId = [guid]::new($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed))).ToString()

    # Matching on the full resource id keeps the result to one row or none. =~ is
    # case-insensitive because ARM is inconsistent about 'resourceGroups' casing.
    $query = "resources`n| where type =~ '$($script:LaResourceType)'`n| where id =~ '$SourceWorkspaceId'`n| project value = id, label = id, selected = true"

    $parameter = [ordered]@{
        id                 = $paramId
        version            = 'KqlParameterItem/1.0'
        name               = $ParameterName
        label              = 'Source workspace (auto)'
        type               = 5
        isGlobal           = $true
        isHiddenWhenLocked = $true
        multiSelect        = $true
        quote              = "'"
        delimiter          = ','
        query              = $query
        queryType          = 1
        resourceType       = $script:ArgResourceType
        description        = 'Added by the Sentinel Workbook Scope Assistant. Resolves to the migration source workspace while it exists, and to nothing once it is deleted, so this workbook keeps working either way. Safe to delete once the source workspace is gone.'
    }

    # Resource Graph searches the subscriptions named here. Without the source
    # subscription an out-of-subscription workspace would never be returned, and
    # the parameter would look permanently empty.
    if ($SourceSubscriptionId) {
        $parameter['crossComponentResources'] = @("/subscriptions/$SourceSubscriptionId")
    }

    return [ordered]@{
        type    = 9
        content = [ordered]@{
            version    = 'KqlParameterItem/1.0'
            parameters = @($parameter)
            style      = 'pills'
            queryType  = 1
        }
        name    = 'wbscope-source-parameter'
    }
}

function Get-ScopeParameterItemIndex {
    <#
    .SYNOPSIS
        Index of the injected parameter item in the root items array, or -1.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Root)

    $items = @(ConvertTo-SafeArray $Root['items'])
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i] -is [System.Collections.IDictionary] -and
            [string]$items[$i]['name'] -eq 'wbscope-source-parameter') {
            return $i
        }
    }
    return -1
}

function Add-ScopeParameter {
    <#
    .SYNOPSIS
        Inserts the scope parameter at the top of the workbook, if not present.
    .DESCRIPTION
        Inserted at index 0 so it evaluates ahead of the content that uses it,
        and so an editor finds it first. This must happen before any manifest
        path is recorded: inserting shifts every items[] index, and a path
        recorded against the pre-insertion tree would point at the wrong node on
        revert.
    .OUTPUTS
        The parameter name in use.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Root,
        [Parameter(Mandatory)][string]$SourceWorkspaceId,
        [string]$SourceSubscriptionId
    )

    $existing = Get-ScopeParameterItemIndex -Root $Root
    if ($existing -ge 0) {
        $items = @(ConvertTo-SafeArray $Root['items'])
        $params = @(ConvertTo-SafeArray $items[$existing]['content']['parameters'])
        if ($params.Count -gt 0) { return [string]$params[0]['name'] }
    }

    $name = Get-ScopeParameterName -Root $Root
    $item = New-ScopeParameterItem -ParameterName $name `
        -SourceWorkspaceId $SourceWorkspaceId -SourceSubscriptionId $SourceSubscriptionId

    $items = [System.Collections.Generic.List[object]]::new()
    $items.Add($item)
    foreach ($existingItem in @(ConvertTo-SafeArray $Root['items'])) { $items.Add($existingItem) }
    $Root['items'] = $items.ToArray()

    return $name
}

function Remove-ScopeParameter {
    <#
    .SYNOPSIS
        Removes the injected parameter item. Returns $true when one was removed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Root)

    $index = Get-ScopeParameterItemIndex -Root $Root
    if ($index -lt 0) { return $false }

    $items = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($item in @(ConvertTo-SafeArray $Root['items'])) {
        if ($i -ne $index) { $items.Add($item) }
        $i++
    }
    $Root['items'] = $items.ToArray()
    return $true
}


# ── Serialisation ─────────────────────────────────────────────────────────────
function ConvertFrom-SerializedWorkbook {
    <#
    .SYNOPSIS
        Parses properties.serializedData into a mutable ordered structure.
    .DESCRIPTION
        -AsHashtable yields OrderedHashtable on PowerShell 7.3+, so key order
        survives the round trip and the resulting diff is confined to what we
        actually changed. On older 7.x the structure is an unordered hashtable:
        still correct, just noisier to diff.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw "Workbook serializedData is empty - nothing to scope."
    }
    return $Json | ConvertFrom-Json -AsHashtable -Depth 100
}

function ConvertTo-SerializedWorkbook {
    <#
    .SYNOPSIS
        Serialises the structure back to the compact JSON string ARM expects.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Root)

    return $Root | ConvertTo-Json -Depth 100 -Compress
}

# ── Traversal ─────────────────────────────────────────────────────────────────
function Get-WorkbookNode {
    <#
    .SYNOPSIS
        Depth-first walk yielding every object node with a stable path.
    .DESCRIPTION
        Generic on purpose. Workbook schemas nest queries under items, groups
        (type 12), tabs, and parameter lists, and the shapes vary by template
        vintage. Walking everything and classifying afterwards is far more robust
        than encoding the known container names, which is how a tool like this
        silently misses a third of a workbook when Microsoft adds a layout type.

        The emitted Path is what -Revert matches against, so it must be built the
        same way on both passes: '$.items[3].content.parameters[0]'.
    .OUTPUTS
        PSCustomObject with Path (string), Node (the live reference), and Parent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Root,
        [string]$Path = '$',
        [object]$Parent = $null,
        [int]$Depth = 0
    )

    # Workbook JSON nests perhaps a dozen levels; 200 is a runaway guard, not a limit.
    if ($Depth -gt 200) { return }
    if ($null -eq $Root) { return }

    if ($Root -is [System.Collections.IDictionary]) {
        [PSCustomObject]@{ Path = $Path; Node = $Root; Parent = $Parent }
        foreach ($key in @($Root.Keys)) {
            # Our own manifest is bookkeeping, not workbook content.
            if ($key -eq $script:ManifestKey) { continue }
            Get-WorkbookNode -Root $Root[$key] -Path "$Path.$key" -Parent $Root -Depth ($Depth + 1)
        }
        return
    }

    if ($Root -is [System.Collections.IEnumerable] -and $Root -isnot [string]) {
        $i = 0
        foreach ($item in $Root) {
            Get-WorkbookNode -Root $item -Path "$Path[$i]" -Parent $Parent -Depth ($Depth + 1)
            $i++
        }
        return
    }
}

# ── Classification ────────────────────────────────────────────────────────────
function Test-EligibleQueryNode {
    <#
    .SYNOPSIS
        True when a node is a Log Analytics query whose scope we may set.
    .DESCRIPTION
        queryType 0 is the Log Analytics query type, but Application Insights
        uses it too and distinguishes itself by resourceType. Scoping an App
        Insights query onto a Log Analytics workspace would break it outright,
        so resourceType is checked rather than assumed.

        An absent resourceType is treated as Log Analytics: that is the default
        for Sentinel workbooks, and such a query is already reading the
        workbook's own workspace.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Node)

    if ($Node -isnot [System.Collections.IDictionary]) { return $false }
    if (-not $Node.Contains('query')) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Node['query'])) { return $false }

    $queryType = 0
    if ($Node.Contains('queryType') -and $null -ne $Node['queryType']) {
        $queryType = [int]$Node['queryType']
    }
    if ($queryType -ne 0) { return $false }

    if ($Node.Contains('resourceType') -and $Node['resourceType']) {
        if ([string]$Node['resourceType'] -ine $script:LaResourceType) { return $false }
    }

    return $true
}

function Get-ScopeReferenceKind {
    <#
    .SYNOPSIS
        Classifies how a node currently declares its scope.
    .OUTPUTS
        'None'      - no crossComponentResources; inherits the workbook default
        'Parameter' - references a parameter, e.g. '{Workspace}'
        'Literal'   - 'value::selected' / 'value::all' / explicit resource IDs
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Node)

    if (-not $Node.Contains('crossComponentResources')) { return 'None' }
    $values = @(ConvertTo-SafeArray $Node['crossComponentResources'])
    if ($values.Count -eq 0) { return 'None' }

    foreach ($v in $values) {
        if ([string]$v -match '^\{.+\}$') { return 'Parameter' }
    }
    return 'Literal'
}

function Get-ReferencedParameterName {
    <#
    .SYNOPSIS
        Extracts the parameter name from a '{Workspace}' style scope reference.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Node)

    foreach ($v in @(ConvertTo-SafeArray $Node['crossComponentResources'])) {
        if ([string]$v -match '^\{(.+)\}$') { return $Matches[1] }
    }
    return $null
}

function Test-IsParameterNode {
    <#
    .SYNOPSIS
        True when a path points at an entry in a parameters array.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return $Path -match '\.parameters\[\d+\]$'
}

# ── Scope list helpers ────────────────────────────────────────────────────────
function Get-DualScopeList {
    <#
    .SYNOPSIS
        Builds the destination-first, de-duplicated resource list.
    .DESCRIPTION
        Destination leads so it stays the workbook's primary context. Comparison
        is case-insensitive because ARM returns resource IDs with inconsistent
        casing - 'resourcegroups' from one endpoint and 'resourceGroups' from
        another - and a case-sensitive dedupe would append the same workspace
        twice on the second run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DestinationWorkspaceId,
        [Parameter(Mandatory)][string]$SourceWorkspaceId,
        [string[]]$Existing = @()
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()

    foreach ($id in @($DestinationWorkspaceId, $SourceWorkspaceId)) {
        if ($seen.Add($id)) { $result.Add($id) }
    }
    # Preserve any other resource the workbook already read - a workbook may
    # legitimately span more than these two workspaces, and dropping the extras
    # would quietly remove data the customer is looking at today.
    foreach ($id in @(ConvertTo-SafeArray $Existing)) {
        $s = [string]$id
        if ($s -match '^\{.+\}$' -or $s -match '^value::') { continue }
        if ($seen.Add($s)) { $result.Add($s) }
    }

    return $result.ToArray()
}

function Test-ScopeListSatisfied {
    <#
    .SYNOPSIS
        True when an existing list already names both workspaces.
    #>
    [CmdletBinding()]
    param(
        [object]$Existing,
        [Parameter(Mandatory)][string]$DestinationWorkspaceId,
        [Parameter(Mandatory)][string]$SourceWorkspaceId
    )

    $values = @(ConvertTo-SafeArray $Existing | ForEach-Object { [string]$_ })
    if ($values.Count -eq 0) { return $false }

    $hasDest = $values | Where-Object { $_ -ieq $DestinationWorkspaceId }
    $hasSrc = $values | Where-Object { $_ -ieq $SourceWorkspaceId }
    return ([bool]$hasDest -and [bool]$hasSrc)
}

# ── Manifest ──────────────────────────────────────────────────────────────────
function Get-DualScopeManifest {
    <#
    .SYNOPSIS
        Reads the embedded manifest, or $null when the workbook is unscoped.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Root)

    if ($Root -isnot [System.Collections.IDictionary]) { return $null }
    if (-not $Root.Contains($script:ManifestKey)) { return $null }
    return $Root[$script:ManifestKey]
}

function Set-DualScopeManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Root,
        [Parameter(Mandatory)][object]$Manifest
    )
    $Root[$script:ManifestKey] = $Manifest
}

function Remove-DualScopeManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Root)
    if ($Root -is [System.Collections.IDictionary] -and $Root.Contains($script:ManifestKey)) {
        $Root.Remove($script:ManifestKey)
    }
}

function New-DualScopeManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceWorkspaceId,
        [Parameter(Mandatory)][string]$DestinationWorkspaceId,
        [Parameter(Mandatory)][object[]]$Changes,
        [string]$ScopeMode = 'SelfHealing',
        [string]$ScopeParameterName
    )

    $manifest = [ordered]@{
        version                = $script:ManifestVersion
        tool                   = $script:ToolName
        # Sortable 'u' format, not ISO 'o', for two reasons. ConvertFrom-Json
        # coerces an ISO-8601 string into a DateTime, and re-serialising that
        # DateTime drops a trailing zero from the 7-digit fractional second - so
        # roughly one run in ten produced a manifest that was not a fixed point
        # under round-trip. 'u' is not recognised as a date, so it survives as
        # the exact string written here and reads back the same in every culture.
        appliedUtc             = (Get-Date).ToUniversalTime().ToString('u')
        scopeMode              = $ScopeMode
        sourceWorkspaceId      = $SourceWorkspaceId
        destinationWorkspaceId = $DestinationWorkspaceId
    }
    if ($ScopeParameterName) { $manifest['scopeParameterName'] = $ScopeParameterName }
    $manifest['changes'] = @($Changes)
    return $manifest
}

# ── Apply ─────────────────────────────────────────────────────────────────────
function Set-WorkbookDualScope {
    <#
    .SYNOPSIS
        Points every eligible Log Analytics query at both workspaces.
    .DESCRIPTION
        Mutates $Root in place and returns a summary. Idempotent: a workbook
        already carrying a manifest for the same workspace pair and scope mode is
        reported as AlreadyScoped and left untouched.
    .PARAMETER ScopeMode
        SelfHealing (default) references the source through a hidden parameter
        that resolves to nothing once the workspace is deleted, so the workbook
        keeps rendering and no revert is needed before decommissioning.

        Literal writes both resource IDs directly. Simpler to read, but the
        workbook stops rendering the moment the source is deleted.
    .PARAMETER SourceSubscriptionId
        In SelfHealing mode, the subscription Resource Graph must search to find
        the source workspace. In Literal mode, used to widen a resource picker
        when the workspaces are in different subscriptions.
    .OUTPUTS
        PSCustomObject: Action, Changes, Stats.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Root,
        [Parameter(Mandatory)][string]$SourceWorkspaceId,
        [Parameter(Mandatory)][string]$DestinationWorkspaceId,
        [ValidateSet('SelfHealing', 'Literal')]
        [string]$ScopeMode = 'SelfHealing',
        [string]$SourceSubscriptionId,
        [string]$DestinationSubscriptionId
    )

    $existing = Get-DualScopeManifest -Root $Root
    if ($existing -and
        [string]$existing['sourceWorkspaceId'] -ieq $SourceWorkspaceId -and
        [string]$existing['destinationWorkspaceId'] -ieq $DestinationWorkspaceId) {
        # A manifest written before scopeMode existed is treated as Literal, so an
        # older run is re-scoped rather than silently left in the fragile mode.
        $existingMode = 'Literal'
        if ($existing.Contains('scopeMode') -and $existing['scopeMode']) { $existingMode = [string]$existing['scopeMode'] }
        if ($existingMode -ieq $ScopeMode) {
            return [PSCustomObject]@{
                Action  = 'AlreadyScoped'
                Changes = @()
                Stats   = [ordered]@{ Eligible = 0; Added = 0; Replaced = 0; ParametersPatched = 0; ScopedViaPicker = 0; Fallback = 0; Skipped = 0 }
            }
        }
    }

    if ($ScopeMode -eq 'SelfHealing') {
        return Set-WorkbookSelfHealingScope -Root $Root `
            -SourceWorkspaceId $SourceWorkspaceId -DestinationWorkspaceId $DestinationWorkspaceId `
            -SourceSubscriptionId $SourceSubscriptionId
    }

    $changes = [System.Collections.Generic.List[object]]::new()
    $stats = [ordered]@{ Eligible = 0; Added = 0; Replaced = 0; ParametersPatched = 0; ScopedViaPicker = 0; Fallback = 0; Skipped = 0 }

    # One walk, materialised, because the parameter patch needs a name lookup
    # that spans the whole tree and the query pass must not re-walk a mutating
    # structure.
    $all = @(Get-WorkbookNode -Root $Root)

    # Index parameters by name for Case C.
    $paramsByName = @{}
    foreach ($entry in $all) {
        if (-not (Test-IsParameterNode -Path $entry.Path)) { continue }
        $n = [string]$entry.Node['name']
        if ($n -and -not $paramsByName.ContainsKey($n)) { $paramsByName[$n] = $entry }
    }

    $paramsToPatch = [ordered]@{}

    foreach ($entry in $all) {
        $node = $entry.Node
        if (-not (Test-EligibleQueryNode -Node $node)) { continue }
        $stats.Eligible++

        switch (Get-ScopeReferenceKind -Node $node) {
            'None' {
                $node['crossComponentResources'] = Get-DualScopeList `
                    -DestinationWorkspaceId $DestinationWorkspaceId -SourceWorkspaceId $SourceWorkspaceId
                $changes.Add([ordered]@{ path = $entry.Path; op = 'added-ccr' })
                $stats.Added++
            }
            'Literal' {
                $original = @(ConvertTo-SafeArray $node['crossComponentResources'] | ForEach-Object { [string]$_ })
                if (Test-ScopeListSatisfied -Existing $original -DestinationWorkspaceId $DestinationWorkspaceId -SourceWorkspaceId $SourceWorkspaceId) {
                    $stats.Skipped++
                    break
                }
                $node['crossComponentResources'] = Get-DualScopeList `
                    -DestinationWorkspaceId $DestinationWorkspaceId -SourceWorkspaceId $SourceWorkspaceId -Existing $original
                $changes.Add([ordered]@{ path = $entry.Path; op = 'replaced-ccr'; original = $original })
                $stats.Replaced++
            }
            'Parameter' {
                # The query keeps pointing at its picker; the picker is what changes.
                $name = Get-ReferencedParameterName -Node $node
                if ($name -and -not $paramsToPatch.Contains($name)) { $paramsToPatch[$name] = $true }
                $stats.Skipped++
            }
        }
    }

    foreach ($name in @($paramsToPatch.Keys)) {
        if (-not $paramsByName.ContainsKey($name)) {
            # Dangling reference. The query falls back to the workbook default,
            # which the fallbackResourceIds change below already covers.
            $changes.Add([ordered]@{ path = '$'; op = 'param-missing'; parameter = $name })
            continue
        }
        $entry = $paramsByName[$name]
        $patched = Set-ParameterDualScope -Entry $entry `
            -SourceWorkspaceId $SourceWorkspaceId -DestinationWorkspaceId $DestinationWorkspaceId `
            -SourceSubscriptionId $SourceSubscriptionId -DestinationSubscriptionId $DestinationSubscriptionId
        if ($patched) {
            $changes.Add($patched)
            $stats.ParametersPatched++
        }
    }

    # The workbook-level default, which every query without its own scope uses.
    if (-not (Test-ScopeListSatisfied -Existing $Root['fallbackResourceIds'] `
                -DestinationWorkspaceId $DestinationWorkspaceId -SourceWorkspaceId $SourceWorkspaceId)) {
        $hadKey = $Root.Contains('fallbackResourceIds')
        $originalFallback = @()
        if ($hadKey) {
            $originalFallback = @(ConvertTo-SafeArray $Root['fallbackResourceIds'] | ForEach-Object { [string]$_ })
        }
        $Root['fallbackResourceIds'] = Get-DualScopeList `
            -DestinationWorkspaceId $DestinationWorkspaceId -SourceWorkspaceId $SourceWorkspaceId -Existing $originalFallback
        $changes.Add([ordered]@{ path = '$'; op = 'extended-fallback'; present = $hadKey; original = $originalFallback })
        $stats.Fallback++
    }

    if ($changes.Count -eq 0) {
        return [PSCustomObject]@{ Action = 'AlreadyScoped'; Changes = @(); Stats = $stats }
    }

    Set-DualScopeManifest -Root $Root -Manifest (New-DualScopeManifest `
            -SourceWorkspaceId $SourceWorkspaceId `
            -DestinationWorkspaceId $DestinationWorkspaceId `
            -ScopeMode 'Literal' `
            -Changes $changes.ToArray())

    return [PSCustomObject]@{ Action = 'Scoped'; Changes = $changes.ToArray(); Stats = $stats }
}

function Set-WorkbookSelfHealingScope {
    <#
    .SYNOPSIS
        Scopes a workbook so it survives the source workspace being deleted.
    .DESCRIPTION
        Each eligible query gets the destination as a hard literal plus a
        reference to the injected parameter. The parameter resolves to the source
        workspace while it exists and to nothing afterwards, at which point the
        reference drops out and the query runs against the destination alone.

        Two things are deliberately NOT done here, and both matter:

        - The customer's own workspace picker is never rewritten. Literal mode
          pins it to both workspaces and counts that as ParametersPatched. Here
          the parameter reference is simply appended alongside it in each query
          and counted as ScopedViaPicker, so the picker keeps the behaviour its
          author intended.
        - fallbackResourceIds is left alone. Putting the source there would write
          a literal that cannot self-heal, reintroducing the exact failure this
          mode exists to remove. Every eligible query gets an explicit scope, so
          the workbook-level default is correctly destination-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Root,
        [Parameter(Mandatory)][string]$SourceWorkspaceId,
        [Parameter(Mandatory)][string]$DestinationWorkspaceId,
        [string]$SourceSubscriptionId
    )

    $changes = [System.Collections.Generic.List[object]]::new()
    $stats = [ordered]@{ Eligible = 0; Added = 0; Replaced = 0; ParametersPatched = 0; ScopedViaPicker = 0; Fallback = 0; Skipped = 0 }

    # Inserted before anything is recorded: it shifts every items[] index, and a
    # path captured against the pre-insertion tree would address the wrong node
    # when revert replays it.
    $paramName = Add-ScopeParameter -Root $Root `
        -SourceWorkspaceId $SourceWorkspaceId -SourceSubscriptionId $SourceSubscriptionId
    $paramRef = "{$paramName}"
    $changes.Add([ordered]@{ path = '$'; op = 'added-scope-parameter'; parameter = $paramName })

    foreach ($entry in @(Get-WorkbookNode -Root $Root)) {
        $node = $entry.Node
        if (-not (Test-EligibleQueryNode -Node $node)) { continue }
        $stats.Eligible++

        $kind = Get-ScopeReferenceKind -Node $node
        $hadKey = $node.Contains('crossComponentResources')
        $original = @()
        if ($hadKey) {
            $original = @(ConvertTo-SafeArray $node['crossComponentResources'] | ForEach-Object { [string]$_ })
        }

        if ($original -contains $paramRef) {
            $stats.Skipped++
            continue
        }

        $newList = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        if ($kind -eq 'Parameter') {
            # Keep the customer's picker exactly as it is and union our source
            # alongside it.
            foreach ($v in $original) { if ($seen.Add($v)) { $newList.Add($v) } }
        }
        else {
            # Destination first so it stays the workbook's primary context, then
            # anything real the query already read, minus tokens we are replacing.
            if ($seen.Add($DestinationWorkspaceId)) { $newList.Add($DestinationWorkspaceId) }
            foreach ($v in $original) {
                if ($v -match '^value::') { continue }
                if ($v -ieq $SourceWorkspaceId) { continue }
                if ($seen.Add($v)) { $newList.Add($v) }
            }
        }
        if ($seen.Add($paramRef)) { $newList.Add($paramRef) }

        $node['crossComponentResources'] = $newList.ToArray()

        if ($kind -eq 'None') {
            $changes.Add([ordered]@{ path = $entry.Path; op = 'added-ccr' })
            $stats.Added++
        }
        else {
            $changes.Add([ordered]@{ path = $entry.Path; op = 'replaced-ccr'; original = $original; present = $hadKey })
            if ($kind -eq 'Parameter') { $stats.ScopedViaPicker++ } else { $stats.Replaced++ }
        }
    }

    Set-DualScopeManifest -Root $Root -Manifest (New-DualScopeManifest `
            -SourceWorkspaceId $SourceWorkspaceId `
            -DestinationWorkspaceId $DestinationWorkspaceId `
            -ScopeMode 'SelfHealing' `
            -ScopeParameterName $paramName `
            -Changes $changes.ToArray())

    return [PSCustomObject]@{ Action = 'Scoped'; Changes = $changes.ToArray(); Stats = $stats }
}

function Set-ParameterDualScope {
    <#
    .SYNOPSIS
        Makes a resource-picker parameter resolve to both workspaces.
    .DESCRIPTION
        A single-select picker cannot hold two values, so it is switched to
        multi-select and given the quote/delimiter pair the Workbooks engine uses
        when it expands a multi-value parameter.

        When the workspaces are in different subscriptions the picker's own
        Resource Graph query is widened too. Left alone, it enumerates only
        '{Subscription}' - one subscription - so the source workspace would not
        appear in the list and the pre-selected value would be rejected.
    .OUTPUTS
        The change record, or $null when nothing needed changing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][string]$SourceWorkspaceId,
        [Parameter(Mandatory)][string]$DestinationWorkspaceId,
        [string]$SourceSubscriptionId,
        [string]$DestinationSubscriptionId
    )

    $p = $Entry.Node
    $scopeList = Get-DualScopeList -DestinationWorkspaceId $DestinationWorkspaceId -SourceWorkspaceId $SourceWorkspaceId

    if ((Test-ScopeListSatisfied -Existing $p['value'] `
                -DestinationWorkspaceId $DestinationWorkspaceId -SourceWorkspaceId $SourceWorkspaceId) -and
        $p['multiSelect'] -eq $true) {
        return $null
    }

    $original = [ordered]@{}
    foreach ($key in @('value', 'multiSelect', 'quote', 'delimiter', 'crossComponentResources', 'isRequired')) {
        $has = $p.Contains($key)
        $original["_had_$key"] = $has
        # Deliberately an if *statement*, never `$x = if (...) { $p[$key] }`. Used
        # as an expression, the value travels the output stream, which unrolls a
        # single-element array into a scalar. crossComponentResources is very
        # often exactly one element, so revert would restore the string
        # "{Subscription}" where the array ["{Subscription}"] had been - valid
        # JSON that the Workbooks engine reads as an empty scope.
        if ($has) { $original[$key] = $p[$key] } else { $original[$key] = $null }
    }

    $p['value'] = $scopeList
    $p['multiSelect'] = $true
    if (-not $p.Contains('quote')) { $p['quote'] = "'" }
    if (-not $p.Contains('delimiter')) { $p['delimiter'] = ',' }

    $crossSubscription = $SourceSubscriptionId -and $DestinationSubscriptionId -and
        ($SourceSubscriptionId -ine $DestinationSubscriptionId)

    if ($crossSubscription -and $p.Contains('crossComponentResources')) {
        $current = @(ConvertTo-SafeArray $p['crossComponentResources'] | ForEach-Object { [string]$_ })
        if ($current | Where-Object { $_ -match '^\{.+\}$' }) {
            $p['crossComponentResources'] = @(
                "/subscriptions/$DestinationSubscriptionId"
                "/subscriptions/$SourceSubscriptionId"
            )
        }
    }

    return [ordered]@{
        path      = $Entry.Path
        op        = 'patched-param'
        parameter = [string]$p['name']
        original  = $original
    }
}

# ── Revert ────────────────────────────────────────────────────────────────────
function Restore-WorkbookScope {
    <#
    .SYNOPSIS
        Undoes dual scoping, restoring destination-only reads.
    .DESCRIPTION
        Uses the embedded manifest when present, so each change is reversed with
        the value it actually had rather than a guess. Falls back to stripping the
        source workspace ID wherever it appears - correct in practice, but it
        cannot tell an array we created from one that was always there, so it
        leaves a single-element list behind rather than deleting the key. An
        explicit scope naming only the destination reads identically to no scope
        at all, so that residue is harmless.
    .OUTPUTS
        PSCustomObject: Action, Method, Changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Root,
        [string]$SourceWorkspaceId
    )

    $manifest = Get-DualScopeManifest -Root $Root
    if ($manifest) {
        $result = Restore-FromManifest -Root $Root -Manifest $manifest
        Remove-DualScopeManifest -Root $Root
        return $result
    }

    if (-not $SourceWorkspaceId) {
        return [PSCustomObject]@{ Action = 'NotScoped'; Method = 'None'; Changes = @() }
    }
    return Restore-ByHeuristic -Root $Root -SourceWorkspaceId $SourceWorkspaceId
}

function Restore-FromManifest {
    <#
    .SYNOPSIS
        Reverses each recorded change at the path it was recorded against.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Root,
        [Parameter(Mandatory)][object]$Manifest
    )

    $byPath = @{}
    foreach ($c in @(ConvertTo-SafeArray $Manifest['changes'])) {
        $path = [string]$c['path']
        if (-not $byPath.ContainsKey($path)) { $byPath[$path] = [System.Collections.Generic.List[object]]::new() }
        $byPath[$path].Add($c)
    }

    $undone = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in @(Get-WorkbookNode -Root $Root)) {
        if (-not $byPath.ContainsKey($entry.Path)) { continue }
        foreach ($c in $byPath[$entry.Path]) {
            switch ([string]$c['op']) {
                'added-ccr' {
                    if ($entry.Node.Contains('crossComponentResources')) {
                        $entry.Node.Remove('crossComponentResources')
                    }
                    $undone.Add($c)
                }
                'replaced-ccr' {
                    # `present` is recorded by self-healing mode; a manifest from
                    # literal mode omits it, and in that mode the key always
                    # existed, so a missing flag means "restore the original".
                    $hadKey = $true
                    if ($c.Contains('present')) { $hadKey = ($c['present'] -eq $true) }
                    if ($hadKey) {
                        $entry.Node['crossComponentResources'] = @(ConvertTo-SafeArray $c['original'] | ForEach-Object { [string]$_ })
                    }
                    elseif ($entry.Node.Contains('crossComponentResources')) {
                        $entry.Node.Remove('crossComponentResources')
                    }
                    $undone.Add($c)
                }
                'patched-param' {
                    $original = $c['original']
                    foreach ($key in @('value', 'multiSelect', 'quote', 'delimiter', 'crossComponentResources', 'isRequired')) {
                        $had = $original["_had_$key"]
                        if ($had -eq $true) { $entry.Node[$key] = $original[$key] }
                        elseif ($entry.Node.Contains($key)) { $entry.Node.Remove($key) }
                    }
                    $undone.Add($c)
                }
            }
        }
    }

    # Root-scoped operations are not reached by the node walk above.
    foreach ($c in @(ConvertTo-SafeArray $Manifest['changes'])) {
        if ([string]$c['op'] -ne 'extended-fallback') { continue }
        if ($c['present'] -eq $true) {
            $Root['fallbackResourceIds'] = @(ConvertTo-SafeArray $c['original'] | ForEach-Object { [string]$_ })
        }
        elseif ($Root.Contains('fallbackResourceIds')) {
            $Root.Remove('fallbackResourceIds')
        }
        $undone.Add($c)
    }

    # Removed last, because taking the item out shifts every items[] index and
    # would invalidate the paths the walk above is still matching against.
    foreach ($c in @(ConvertTo-SafeArray $Manifest['changes'])) {
        if ([string]$c['op'] -ne 'added-scope-parameter') { continue }
        if (Remove-ScopeParameter -Root $Root) { $undone.Add($c) }
    }

    return [PSCustomObject]@{ Action = 'Reverted'; Method = 'Manifest'; Changes = $undone.ToArray() }
}

function Restore-ByHeuristic {
    <#
    .SYNOPSIS
        Strips the source workspace from every scope list in the workbook.
    .DESCRIPTION
        Covers both modes: the literal source resource ID, and the self-healing
        parameter reference along with the parameter item itself. Used only when
        neither a snapshot nor a manifest is available, so it works from what the
        workbook currently says rather than from a record of what was changed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Root,
        [Parameter(Mandatory)][string]$SourceWorkspaceId
    )

    $undone = [System.Collections.Generic.List[object]]::new()

    # Identify the injected parameter first so its reference can be stripped in
    # the same pass as the literal.
    $paramRefs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $paramIndex = Get-ScopeParameterItemIndex -Root $Root
    if ($paramIndex -ge 0) {
        $items = @(ConvertTo-SafeArray $Root['items'])
        foreach ($p in @(ConvertTo-SafeArray $items[$paramIndex]['content']['parameters'])) {
            $n = [string]$p['name']
            if ($n) { [void]$paramRefs.Add("{$n}") }
        }
    }

    foreach ($entry in @(Get-WorkbookNode -Root $Root)) {
        if ($entry.Node -isnot [System.Collections.IDictionary]) { continue }
        if (-not $entry.Node.Contains('crossComponentResources')) { continue }
        $values = @(ConvertTo-SafeArray $entry.Node['crossComponentResources'] | ForEach-Object { [string]$_ })
        $kept = @($values | Where-Object { $_ -ine $SourceWorkspaceId -and -not $paramRefs.Contains($_) })
        if ($kept.Count -eq $values.Count) { continue }

        if ($kept.Count -eq 0) { $entry.Node.Remove('crossComponentResources') }
        else { $entry.Node['crossComponentResources'] = $kept }
        $undone.Add([ordered]@{ path = $entry.Path; op = 'stripped-ccr' })
    }

    if ($Root.Contains('fallbackResourceIds')) {
        $values = @(ConvertTo-SafeArray $Root['fallbackResourceIds'] | ForEach-Object { [string]$_ })
        $kept = @($values | Where-Object { $_ -ine $SourceWorkspaceId })
        if ($kept.Count -ne $values.Count) {
            if ($kept.Count -eq 0) { $Root.Remove('fallbackResourceIds') }
            else { $Root['fallbackResourceIds'] = $kept }
            $undone.Add([ordered]@{ path = '$'; op = 'stripped-fallback' })
        }
    }

    # Last, for the same index-shifting reason as the manifest path.
    if (Remove-ScopeParameter -Root $Root) {
        $undone.Add([ordered]@{ path = '$'; op = 'removed-scope-parameter' })
    }

    $action = if ($undone.Count -gt 0) { 'Reverted' } else { 'NotScoped' }
    return [PSCustomObject]@{ Action = $action; Method = 'Heuristic'; Changes = $undone.ToArray() }
}

# ── Analysis (dry run / reporting) ────────────────────────────────────────────
function Get-WorkbookScopeSummary {
    <#
    .SYNOPSIS
        Counts what a workbook contains without changing anything.
    .DESCRIPTION
        Backs the dry-run report, so an operator sees the shape of the change
        before any of it is written.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Root)

    $summary = [ordered]@{
        TotalQueries      = 0
        Eligible          = 0
        NoScope           = 0
        LiteralScope      = 0
        ParameterScope    = 0
        Ineligible        = 0
        ParameterNames    = @()
        AlreadyDualScoped = $false
    }

    $paramNames = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($entry in @(Get-WorkbookNode -Root $Root)) {
        $node = $entry.Node
        if (-not $node.Contains('query')) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$node['query'])) { continue }
        $summary.TotalQueries++

        if (-not (Test-EligibleQueryNode -Node $node)) {
            $summary.Ineligible++
            continue
        }
        $summary.Eligible++

        switch (Get-ScopeReferenceKind -Node $node) {
            'None' { $summary.NoScope++ }
            'Literal' { $summary.LiteralScope++ }
            'Parameter' {
                $summary.ParameterScope++
                $n = Get-ReferencedParameterName -Node $node
                if ($n) { [void]$paramNames.Add($n) }
            }
        }
    }

    $summary.ParameterNames = @($paramNames)
    $summary.AlreadyDualScoped = [bool](Get-DualScopeManifest -Root $Root)
    return [PSCustomObject]$summary
}

function Get-WorkbookQueryTable {
    <#
    .SYNOPSIS
        Best-effort list of Log Analytics tables a workbook reads.
    .DESCRIPTION
        Feeds -ValidateQueries, which compares the tables a workbook needs
        against what each workspace actually holds.

        This is a heuristic and is labelled as one wherever it surfaces. A table
        reference appears in two places worth finding: at the head of a
        statement, and as an operand of union or join. Everything after a pipe is
        an operator, not a table, so pipe segments are only inspected when they
        begin with union or join.

        A full KQL parser is not worth carrying for a reporting aid - a wrong
        guess here costs a spurious report line, not a broken workbook.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Root)

    $tables = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Statement-initial words that introduce something other than a table.
    $notTables = @(
        'let', 'set', 'declare', 'print', 'range', 'search', 'find', 'datatable',
        'externaldata', 'evaluate', 'invoke', 'union', 'join', 'materialize',
        'toscalar', 'view', 'restrict', 'alias', 'pattern'
    )

    foreach ($entry in @(Get-WorkbookNode -Root $Root)) {
        $node = $entry.Node
        if (-not (Test-EligibleQueryNode -Node $node)) { continue }

        $query = [string]$node['query']
        # Strip line comments so a commented-out table is not reported.
        $query = ($query -split '\r?\n' | ForEach-Object { $_ -replace '//.*$', '' }) -join "`n"

        # Names bound by `let` are query-local, not tables. They are the largest
        # source of false positives by far: a workbook that defines `let cats =
        # datatable(...)` and then pipes from `cats` would otherwise be reported
        # as depending on a table named 'cats' that exists in neither workspace.
        $letNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($m in [regex]::Matches($query, '(?im)^\s*let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=')) {
            [void]$letNames.Add($m.Groups[1].Value)
        }

        # Remove string literals and parenthesised groups before splitting.
        # A multi-line case() or iff() otherwise leaves bare words such as
        # 'high', 'low' and 'string' sitting alone on a line, which then read as
        # statement-initial table references. Removing the interiors is cheaper
        # and more reliable than trying to recognise each construct.
        $scrubbed = $query -replace '"(?:[^"\\]|\\.)*"', '""' -replace "'(?:[^'\\]|\\.)*'", "''"
        $previous = $null
        while ($scrubbed -ne $previous) {
            $previous = $scrubbed
            $scrubbed = $scrubbed -replace '\([^()]*\)', '()'
        }

        $addCandidate = {
            param([string]$Name)
            if (-not $Name) { return }
            if ($Name.ToLowerInvariant() -in $notTables) { return }
            if ($letNames.Contains($Name)) { return }
            if ($Name -match '^\d') { return }
            [void]$tables.Add($Name)
        }

        foreach ($statement in ($scrubbed -split ';')) {
            $segments = $statement -split '\|'
            for ($i = 0; $i -lt $segments.Count; $i++) {
                $seg = $segments[$i].Trim()
                if (-not $seg) { continue }

                # Only the head of a statement names a bare table, and only when
                # the identifier stands alone - 'T' or 'T | where'. Requiring
                # that keeps expressions such as 'Category = tostring(x)' out.
                if ($i -eq 0 -and $seg -match '^([A-Za-z_][A-Za-z0-9_]*)\s*$') {
                    & $addCandidate $Matches[1]
                }

                # union and join name their tables as operands. Options such as
                # kind=inner or withsource=Table are skipped by requiring the
                # candidate not to be followed by '='.
                if ($seg -match '^(union|join)\b(.*)$') {
                    $operands = $Matches[2]
                    foreach ($m in [regex]::Matches($operands, '(?<![\w=])([A-Za-z_][A-Za-z0-9_]*)\s*(?![\w\s]*=)')) {
                        $candidate = $m.Groups[1].Value
                        if ($candidate.ToLowerInvariant() -in @('kind', 'withsource', 'isfuzzy', 'inner', 'outer', 'leftouter', 'rightouter', 'fullouter', 'leftanti', 'rightanti', 'leftsemi', 'rightsemi', 'on', 'hint', 'true', 'false')) { continue }
                        & $addCandidate $candidate
                    }
                }
            }
        }
    }

    return @($tables)
}

Export-ModuleMember -Function @(
    'ConvertFrom-SerializedWorkbook'
    'ConvertTo-SerializedWorkbook'
    'Get-WorkbookNode'
    'Test-EligibleQueryNode'
    'Get-ScopeReferenceKind'
    'Get-ReferencedParameterName'
    'Test-IsParameterNode'
    'Get-DualScopeList'
    'Test-ScopeListSatisfied'
    'Get-DualScopeManifest'
    'Set-DualScopeManifest'
    'Remove-DualScopeManifest'
    'New-DualScopeManifest'
    'Set-WorkbookDualScope'
    'Set-WorkbookSelfHealingScope'
    'Set-ParameterDualScope'
    'Restore-WorkbookScope'
    'Restore-FromManifest'
    'Restore-ByHeuristic'
    'Get-WorkbookScopeSummary'
    'Get-WorkbookQueryTable'
    'Get-ScopeParameterName'
    'New-ScopeParameterItem'
    'Get-ScopeParameterItemIndex'
    'Add-ScopeParameter'
    'Remove-ScopeParameter'
)
