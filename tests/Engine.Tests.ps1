<#
    Tests for the scope transform.

    The engine is deliberately network-free, which is what lets these tests run
    the entire real-world corpus offline: 16 workbooks and 533 Log Analytics
    queries captured from an actual migration, sanitised of customer identifiers.

    The properties asserted here are the ones that matter to a customer:
      - every eligible query ends up reading both workspaces
      - nothing ineligible is touched
      - applying twice changes nothing the second time
      - revert returns the workbook byte-for-byte
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Engine.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Common.psm1') -Force -DisableNameChecking

    $script:SourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-src/providers/Microsoft.OperationalInsights/workspaces/ws-source'
    $script:DestId = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-dest/providers/Microsoft.OperationalInsights/workspaces/ws-dest'
    $script:SourceSub = '11111111-1111-1111-1111-111111111111'
    $script:DestSub = '22222222-2222-2222-2222-222222222222'

    $fixturePath = Join-Path $PSScriptRoot 'fixtures\workbooks.json'
    $script:Corpus = @(Get-Content $fixturePath -Raw | ConvertFrom-Json)

    function New-TestRoot {
        param([string]$Json)
        return ConvertFrom-SerializedWorkbook -Json $Json
    }
}

Describe 'Serialisation round-trip' {

    It 'parses and re-serialises every corpus workbook without loss' {
        foreach ($wb in $script:Corpus) {
            $root = ConvertFrom-SerializedWorkbook -Json $wb.properties.serializedData
            $once = ConvertTo-SerializedWorkbook -Root $root
            $twice = ConvertTo-SerializedWorkbook -Root (ConvertFrom-SerializedWorkbook -Json $once)
            $twice | Should -BeExactly $once -Because "$($wb.properties.displayName) must be a fixed point under re-serialisation"
        }
    }

    It 'rejects empty serializedData rather than producing an empty workbook' {
        { ConvertFrom-SerializedWorkbook -Json '' } | Should -Throw
    }
}

Describe 'Query classification' {

    It 'treats a Log Analytics query as eligible' {
        $node = @{ query = 'Heartbeat | take 1'; queryType = 0; resourceType = 'microsoft.operationalinsights/workspaces' }
        Test-EligibleQueryNode -Node $node | Should -BeTrue
    }

    It 'treats an absent resourceType as Log Analytics' {
        # The default for Sentinel workbooks; such a query already reads the
        # workbook's own workspace.
        $node = @{ query = 'Heartbeat'; queryType = 0 }
        Test-EligibleQueryNode -Node $node | Should -BeTrue
    }

    It 'excludes Azure Resource Graph queries' {
        $node = @{ query = 'resources | take 1'; queryType = 1; resourceType = 'microsoft.resourcegraph/resources' }
        Test-EligibleQueryNode -Node $node | Should -BeFalse
    }

    It 'excludes Application Insights, which shares queryType 0' {
        # Scoping an App Insights query onto a Log Analytics workspace breaks it,
        # so resourceType has to be checked rather than assumed.
        $node = @{ query = 'requests'; queryType = 0; resourceType = 'microsoft.insights/components' }
        Test-EligibleQueryNode -Node $node | Should -BeFalse
    }

    It 'excludes a node with no query, and one with an empty query' {
        Test-EligibleQueryNode -Node @{ queryType = 0 } | Should -BeFalse
        Test-EligibleQueryNode -Node @{ query = '   '; queryType = 0 } | Should -BeFalse
    }

    It 'classifies scope references' {
        Get-ScopeReferenceKind -Node @{ query = 'x' } | Should -Be 'None'
        Get-ScopeReferenceKind -Node @{ query = 'x'; crossComponentResources = @() } | Should -Be 'None'
        Get-ScopeReferenceKind -Node @{ query = 'x'; crossComponentResources = @('{Workspace}') } | Should -Be 'Parameter'
        Get-ScopeReferenceKind -Node @{ query = 'x'; crossComponentResources = @('value::all') } | Should -Be 'Literal'
    }

    It 'extracts the referenced parameter name' {
        Get-ReferencedParameterName -Node @{ crossComponentResources = @('{Workspaces}') } | Should -Be 'Workspaces'
    }
}

Describe 'Scope list construction' {

    It 'puts the destination first so it stays the primary context' {
        $list = Get-DualScopeList -DestinationWorkspaceId $script:DestId -SourceWorkspaceId $script:SourceId
        $list[0] | Should -Be $script:DestId
        $list[1] | Should -Be $script:SourceId
    }

    It 'de-duplicates case-insensitively' {
        # ARM returns 'resourcegroups' from one endpoint and 'resourceGroups'
        # from another. A case-sensitive dedupe would append the same workspace
        # twice on the second run.
        $variant = $script:SourceId -replace 'resourceGroups', 'resourcegroups'
        $list = Get-DualScopeList -DestinationWorkspaceId $script:DestId `
            -SourceWorkspaceId $script:SourceId -Existing @($variant)
        @($list).Count | Should -Be 2
    }

    It 'preserves an unrelated third workspace already in the list' {
        # A workbook may legitimately span more than these two workspaces, and
        # dropping the extras would remove data the customer reads today.
        $other = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-x/providers/Microsoft.OperationalInsights/workspaces/ws-other'
        $list = Get-DualScopeList -DestinationWorkspaceId $script:DestId `
            -SourceWorkspaceId $script:SourceId -Existing @($other)
        $list | Should -Contain $other
    }

    It 'drops parameter and literal tokens rather than carrying them through' {
        $list = Get-DualScopeList -DestinationWorkspaceId $script:DestId `
            -SourceWorkspaceId $script:SourceId -Existing @('{Workspace}', 'value::all')
        @($list).Count | Should -Be 2
    }
}

Describe 'Applying dual scope to the real corpus' {

    BeforeAll {
        $script:Applied = @()
        foreach ($wb in $script:Corpus) {
            $root = ConvertFrom-SerializedWorkbook -Json $wb.properties.serializedData
            $before = Get-WorkbookScopeSummary -Root $root
            $result = Set-WorkbookDualScope -Root $root `
                -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId `
                -ScopeMode Literal -SourceSubscriptionId $script:SourceSub -DestinationSubscriptionId $script:DestSub
            $script:Applied += [PSCustomObject]@{
                Name     = $wb.properties.displayName
                Root     = $root
                Summary  = $before
                Result   = $result
                Original = $wb.properties.serializedData
            }
        }
    }

    It 'exercises a corpus large enough to be meaningful' {
        $totalEligible = ($script:Applied | Measure-Object -Property { $_.Summary.Eligible } -Sum).Sum
        $totalEligible | Should -BeGreaterThan 400
    }

    It 'leaves every eligible query reading both workspaces' {
        $unresolved = 0
        foreach ($entry in $script:Applied) {
            $nodes = @(Get-WorkbookNode -Root $entry.Root)
            foreach ($n in $nodes) {
                if (-not (Test-EligibleQueryNode -Node $n.Node)) { continue }

                if ((Get-ScopeReferenceKind -Node $n.Node) -eq 'Parameter') {
                    # The query still points at its picker; the picker is what
                    # carries both workspaces.
                    $pname = Get-ReferencedParameterName -Node $n.Node
                    $param = @($nodes | Where-Object {
                            (Test-IsParameterNode -Path $_.Path) -and [string]$_.Node['name'] -eq $pname
                        }) | Select-Object -First 1
                    if (-not $param) { continue }
                    if (-not (Test-ScopeListSatisfied -Existing $param.Node['value'] `
                                -DestinationWorkspaceId $script:DestId -SourceWorkspaceId $script:SourceId)) {
                        $unresolved++
                    }
                }
                elseif (-not (Test-ScopeListSatisfied -Existing $n.Node['crossComponentResources'] `
                            -DestinationWorkspaceId $script:DestId -SourceWorkspaceId $script:SourceId)) {
                    $unresolved++
                }
            }
        }
        $unresolved | Should -Be 0
    }

    It 'never adds the source workspace to an ineligible query' {
        # Resource Graph, Application Insights and metrics queries would break.
        $touched = 0
        foreach ($entry in $script:Applied) {
            foreach ($n in @(Get-WorkbookNode -Root $entry.Root)) {
                $node = $n.Node
                if ($node -isnot [System.Collections.IDictionary]) { continue }
                if (-not $node.Contains('query')) { continue }
                if (Test-EligibleQueryNode -Node $node) { continue }
                if (-not $node.Contains('crossComponentResources')) { continue }
                $values = @($node['crossComponentResources'] | ForEach-Object { [string]$_ })
                if ($values -contains $script:SourceId) { $touched++ }
            }
        }
        $touched | Should -Be 0
    }

    It 'never modifies any KQL' {
        foreach ($entry in $script:Applied) {
            $before = @(ConvertFrom-SerializedWorkbook -Json $entry.Original |
                    ForEach-Object { Get-WorkbookNode -Root $_ } |
                    Where-Object { $_.Node -is [System.Collections.IDictionary] -and $_.Node.Contains('query') } |
                    ForEach-Object { [string]$_.Node['query'] })
            $after = @(Get-WorkbookNode -Root $entry.Root |
                    Where-Object { $_.Node -is [System.Collections.IDictionary] -and $_.Node.Contains('query') } |
                    ForEach-Object { [string]$_.Node['query'] })
            ($after -join "`n") | Should -BeExactly ($before -join "`n") -Because "$($entry.Name) must have identical query text"
        }
    }

    It 'writes a manifest recording both workspaces' {
        foreach ($entry in $script:Applied) {
            if ($entry.Result.Action -ne 'Scoped') { continue }
            $manifest = Get-DualScopeManifest -Root $entry.Root
            $manifest | Should -Not -BeNullOrEmpty
            [string]$manifest['sourceWorkspaceId'] | Should -Be $script:SourceId
            [string]$manifest['destinationWorkspaceId'] | Should -Be $script:DestId
        }
    }

    It 'is idempotent - a second apply changes nothing' {
        foreach ($entry in $script:Applied) {
            $json = ConvertTo-SerializedWorkbook -Root $entry.Root
            $again = ConvertFrom-SerializedWorkbook -Json $json
            $second = Set-WorkbookDualScope -Root $again `
                -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId -ScopeMode Literal
            $second.Action | Should -Be 'AlreadyScoped' -Because "$($entry.Name) was already scoped"
            (ConvertTo-SerializedWorkbook -Root $again) | Should -BeExactly $json
        }
    }

    It 'produces a manifest that survives a JSON round-trip' {
        # ConvertFrom-Json coerces an ISO-8601 timestamp into a DateTime, and
        # re-serialising drops a trailing zero from the 7-digit fraction - which
        # made roughly one run in ten non-idempotent. Guards that regression.
        foreach ($entry in $script:Applied) {
            $json = ConvertTo-SerializedWorkbook -Root $entry.Root
            $again = ConvertTo-SerializedWorkbook -Root (ConvertFrom-SerializedWorkbook -Json $json)
            $again | Should -BeExactly $json -Because "$($entry.Name) manifest must be a fixed point"
        }
    }

    It 'reports literal parameter rewrites separately from picker-preserving scope' {
        $parametersPatched = 0
        $scopedViaPicker = 0
        foreach ($entry in $script:Applied) {
            $parametersPatched += [int]$entry.Result.Stats.ParametersPatched
            $entry.Result.Stats.ScopedViaPicker | Should -Be 0 -Because "$($entry.Name) was scoped in literal mode"
            $scopedViaPicker += [int]$entry.Result.Stats.ScopedViaPicker
        }
        $parametersPatched | Should -BeGreaterThan 0
        $scopedViaPicker | Should -Be 0
    }
}

Describe 'Reverting' {

    It 'restores every corpus workbook byte-for-byte via the manifest' {
        foreach ($wb in $script:Corpus) {
            $original = $wb.properties.serializedData
            $root = ConvertFrom-SerializedWorkbook -Json $original
            $baseline = ConvertTo-SerializedWorkbook -Root $root

            $null = Set-WorkbookDualScope -Root $root `
                -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId `
                -ScopeMode Literal -SourceSubscriptionId $script:SourceSub -DestinationSubscriptionId $script:DestSub

            $rev = Restore-WorkbookScope -Root $root -SourceWorkspaceId $script:SourceId
            $rev.Method | Should -Be 'Manifest'
            (ConvertTo-SerializedWorkbook -Root $root) | Should -BeExactly $baseline -Because "$($wb.properties.displayName) must revert exactly"
        }
    }

    It 'restores byte-for-byte after a save and reload, which is the real revert path' {
        # -Revert reads the workbook back from ARM rather than holding it in
        # memory, so the manifest has been through a JSON round-trip by then.
        foreach ($wb in $script:Corpus) {
            $root = ConvertFrom-SerializedWorkbook -Json $wb.properties.serializedData
            $baseline = ConvertTo-SerializedWorkbook -Root $root

            $null = Set-WorkbookDualScope -Root $root `
                -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId `
                -ScopeMode Literal -SourceSubscriptionId $script:SourceSub -DestinationSubscriptionId $script:DestSub

            $reloaded = ConvertFrom-SerializedWorkbook -Json (ConvertTo-SerializedWorkbook -Root $root)
            $null = Restore-WorkbookScope -Root $reloaded -SourceWorkspaceId $script:SourceId
            (ConvertTo-SerializedWorkbook -Root $reloaded) | Should -BeExactly $baseline
        }
    }

    It 'preserves a single-element array rather than unrolling it to a scalar' {
        # `$x = if (...) { $arr }` used as an expression sends the value through
        # the output stream, which unrolls a one-element array into a string.
        # crossComponentResources is very often exactly one element, so revert
        # restored "{Subscription}" where ["{Subscription}"] had been - valid
        # JSON that the Workbooks engine reads as an empty scope.
        $json = '{"version":"Notebook/1.0","items":[{"type":9,"content":{"parameters":[{"id":"p1","version":"KqlParameterItem/1.0","name":"Workspace","type":5,"query":"resources","crossComponentResources":["{Subscription}"],"queryType":1,"resourceType":"microsoft.resourcegraph/resources"}]},"name":"params"},{"type":3,"content":{"query":"Heartbeat","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","crossComponentResources":["{Workspace}"]},"name":"q1"}]}'
        $root = ConvertFrom-SerializedWorkbook -Json $json
        $baseline = ConvertTo-SerializedWorkbook -Root $root

        $null = Set-WorkbookDualScope -Root $root `
            -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId `
            -ScopeMode Literal -SourceSubscriptionId $script:SourceSub -DestinationSubscriptionId $script:DestSub
        $null = Restore-WorkbookScope -Root $root -SourceWorkspaceId $script:SourceId

        $restored = ConvertTo-SerializedWorkbook -Root $root
        $restored | Should -BeExactly $baseline
        $restored | Should -Match '"crossComponentResources":\["\{Subscription\}"\]'
    }

    It 'falls back to the heuristic when no manifest is present' {
        $json = '{"version":"Notebook/1.0","items":[{"type":3,"content":{"query":"Heartbeat","queryType":0,"crossComponentResources":["' +
        $script:DestId + '","' + $script:SourceId + '"]},"name":"q1"}]}'
        $root = ConvertFrom-SerializedWorkbook -Json $json
        $rev = Restore-WorkbookScope -Root $root -SourceWorkspaceId $script:SourceId

        $rev.Method | Should -Be 'Heuristic'
        $rev.Action | Should -Be 'Reverted'
        (ConvertTo-SerializedWorkbook -Root $root) | Should -Not -Match ([regex]::Escape($script:SourceId))
    }

    It 'reports NotScoped for a workbook it never touched' {
        $json = '{"version":"Notebook/1.0","items":[{"type":3,"content":{"query":"Heartbeat","queryType":0},"name":"q1"}]}'
        $root = ConvertFrom-SerializedWorkbook -Json $json
        $rev = Restore-WorkbookScope -Root $root -SourceWorkspaceId $script:SourceId
        $rev.Action | Should -Be 'NotScoped'
    }
}

Describe 'Cross-subscription handling' {

    It 'widens a picker scoped to a single subscription' {
        # The picker enumerates workspaces via Resource Graph scoped to
        # {Subscription}. Left alone, the source workspace would not appear in
        # the list at all and the pre-selected value would be rejected.
        $json = '{"version":"Notebook/1.0","items":[{"type":9,"content":{"parameters":[{"id":"p1","version":"KqlParameterItem/1.0","name":"Workspace","type":5,"query":"resources","crossComponentResources":["{Subscription}"],"queryType":1,"resourceType":"microsoft.resourcegraph/resources"}]},"name":"params"},{"type":3,"content":{"query":"Heartbeat","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","crossComponentResources":["{Workspace}"]},"name":"q1"}]}'
        $root = ConvertFrom-SerializedWorkbook -Json $json

        $null = Set-WorkbookDualScope -Root $root `
            -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId `
            -ScopeMode Literal -SourceSubscriptionId $script:SourceSub -DestinationSubscriptionId $script:DestSub

        $out = ConvertTo-SerializedWorkbook -Root $root
        $out | Should -Match ([regex]::Escape("/subscriptions/$($script:SourceSub)"))
    }

    It 'leaves the picker scope alone when both workspaces share a subscription' {
        $json = '{"version":"Notebook/1.0","items":[{"type":9,"content":{"parameters":[{"id":"p1","version":"KqlParameterItem/1.0","name":"Workspace","type":5,"query":"resources","crossComponentResources":["{Subscription}"],"queryType":1,"resourceType":"microsoft.resourcegraph/resources"}]},"name":"params"},{"type":3,"content":{"query":"Heartbeat","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","crossComponentResources":["{Workspace}"]},"name":"q1"}]}'
        $root = ConvertFrom-SerializedWorkbook -Json $json
        $sameSubSource = $script:SourceId -replace [regex]::Escape($script:SourceSub), $script:DestSub

        $null = Set-WorkbookDualScope -Root $root `
            -SourceWorkspaceId $sameSubSource -DestinationWorkspaceId $script:DestId `
            -ScopeMode Literal -SourceSubscriptionId $script:DestSub -DestinationSubscriptionId $script:DestSub

        (ConvertTo-SerializedWorkbook -Root $root) | Should -Match '\{Subscription\}'
    }
}

Describe 'Table extraction for validation' {

    It 'finds table names without tripping over KQL operators' {
        $json = '{"version":"Notebook/1.0","items":[{"type":3,"content":{"query":"let x = 5;\nSecurityEvent | where EventID == 1\n| union Heartbeat","queryType":0},"name":"q1"}]}'
        $root = ConvertFrom-SerializedWorkbook -Json $json
        $tables = @(Get-WorkbookQueryTable -Root $root)

        $tables | Should -Contain 'SecurityEvent'
        $tables | Should -Contain 'Heartbeat'
        $tables | Should -Not -Contain 'let'
        $tables | Should -Not -Contain 'union'
    }
}

Describe 'Self-healing scope' {

    BeforeAll {
        $script:Healed = @()
        foreach ($wb in $script:Corpus) {
            $root = ConvertFrom-SerializedWorkbook -Json $wb.properties.serializedData
            $baseline = ConvertTo-SerializedWorkbook -Root $root
            $result = Set-WorkbookDualScope -Root $root `
                -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId `
                -ScopeMode SelfHealing `
                -SourceSubscriptionId $script:SourceSub -DestinationSubscriptionId $script:DestSub
            $manifest = Get-DualScopeManifest -Root $root
            $script:Healed += [PSCustomObject]@{
                Name      = $wb.properties.displayName
                Root      = $root
                Baseline  = $baseline
                Result    = $result
                ParamName = [string]$manifest['scopeParameterName']
                Json      = ConvertTo-SerializedWorkbook -Root $root
            }
        }
    }

    It 'is the default mode' {
        # Chosen deliberately: the literal default left workbooks that broke the
        # moment the source workspace was deleted.
        $json = '{"version":"Notebook/1.0","items":[{"type":3,"content":{"query":"Heartbeat","queryType":0},"name":"q1"}]}'
        $root = ConvertFrom-SerializedWorkbook -Json $json
        $null = Set-WorkbookDualScope -Root $root `
            -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId
        [string](Get-DualScopeManifest -Root $root)['scopeMode'] | Should -Be 'SelfHealing'
    }

    It 'never marks the injected parameter as required' {
        # The single most important detail in the design. A required picker with
        # no results blocks every query that depends on it, which would turn the
        # graceful degradation into a hard failure at exactly the wrong moment.
        foreach ($entry in $script:Healed) {
            foreach ($e in @(Get-WorkbookNode -Root $entry.Root)) {
                if (-not (Test-IsParameterNode -Path $e.Path)) { continue }
                if ([string]$e.Node['name'] -ne $entry.ParamName) { continue }
                $e.Node.Contains('isRequired') | Should -BeFalse -Because "$($entry.Name) must let the scope parameter resolve to empty"
            }
        }
    }

    It 'marks the injected parameter global and hidden' {
        foreach ($entry in $script:Healed) {
            foreach ($e in @(Get-WorkbookNode -Root $entry.Root)) {
                if (-not (Test-IsParameterNode -Path $e.Path)) { continue }
                if ([string]$e.Node['name'] -ne $entry.ParamName) { continue }
                # Global, or queries inside nested groups cannot resolve it - the
                # corpus nests parameter blocks four levels deep.
                $e.Node['isGlobal'] | Should -BeTrue
                $e.Node['isHiddenWhenLocked'] | Should -BeTrue
            }
        }
    }

    It 'writes no literal source reference outside the parameter query and manifest' {
        # The manifest is inert bookkeeping and the ARG query is a filter, not a
        # resource reference the Workbooks engine resolves. Anything else naming
        # the source workspace would break when it is deleted.
        foreach ($entry in $script:Healed) {
            $stripped = ConvertFrom-SerializedWorkbook -Json $entry.Json
            $null = Remove-ScopeParameter -Root $stripped
            Remove-DualScopeManifest -Root $stripped
            (ConvertTo-SerializedWorkbook -Root $stripped) |
                Should -Not -Match ([regex]::Escape($script:SourceId)) -Because "$($entry.Name) would break when the source is deleted"
        }
    }

    It 'leaves every query with a usable scope after the source workspace is deleted' {
        # The whole point. Deleting the workspace removes it from Resource Graph,
        # so the parameter resolves empty and its reference drops out. Simulated
        # here by removing the parameter and discarding its references.
        foreach ($entry in $script:Healed) {
            $paramRef = "{$($entry.ParamName)}"
            $deleted = ConvertFrom-SerializedWorkbook -Json $entry.Json
            $null = Remove-ScopeParameter -Root $deleted

            foreach ($e in @(Get-WorkbookNode -Root $deleted)) {
                if (-not (Test-EligibleQueryNode -Node $e.Node)) { continue }
                $remaining = @(ConvertTo-SafeArray $e.Node['crossComponentResources'] |
                        ForEach-Object { [string]$_ } | Where-Object { $_ -ne $paramRef })
                $usable = @($remaining | Where-Object {
                        $_ -ieq $script:DestId -or $_ -match '^\{.+\}$' -or $_ -match '^value::'
                    })
                $usable.Count | Should -BeGreaterThan 0 -Because "$($entry.Name) at $($e.Path) must still resolve to the destination"
            }
        }
    }

    It 'never touches fallbackResourceIds' {
        # A literal there cannot self-heal, so writing the source into it would
        # reintroduce the exact failure this mode exists to remove.
        foreach ($entry in $script:Healed) {
            $before = ConvertFrom-SerializedWorkbook -Json $entry.Baseline
            ($entry.Root['fallbackResourceIds'] | ConvertTo-Json -Depth 5 -Compress) |
                Should -BeExactly ($before['fallbackResourceIds'] | ConvertTo-Json -Depth 5 -Compress) -Because "$($entry.Name) must keep its original default scope"
        }
    }

    It 'leaves the customer workspace picker unpinned' {
        # Literal mode pins the picker to both workspaces, which is what makes it
        # break on deletion. Here the reference is appended beside it instead, so
        # the picker keeps the behaviour its author intended.
        $json = '{"version":"Notebook/1.0","items":[{"type":9,"content":{"parameters":[{"id":"p1","version":"KqlParameterItem/1.0","name":"Workspace","type":5,"query":"resources","crossComponentResources":["{Subscription}"],"queryType":1,"resourceType":"microsoft.resourcegraph/resources"}]},"name":"params"},{"type":3,"content":{"query":"Heartbeat","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","crossComponentResources":["{Workspace}"]},"name":"q1"}]}'
        $root = ConvertFrom-SerializedWorkbook -Json $json
        $null = Set-WorkbookDualScope -Root $root `
            -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId `
            -ScopeMode SelfHealing -SourceSubscriptionId $script:SourceSub -DestinationSubscriptionId $script:DestSub

        $picker = @(Get-WorkbookNode -Root $root | Where-Object {
                (Test-IsParameterNode -Path $_.Path) -and [string]$_.Node['name'] -eq 'Workspace'
            })[0].Node
        $picker.Contains('value') | Should -BeFalse -Because 'the picker must not be pinned to a fixed pair of workspaces'
        $picker['crossComponentResources'] | Should -Be @('{Subscription}')
    }

    It 'reports picker-preserving query scope without claiming parameter rewrites' {
        $parametersPatched = 0
        $scopedViaPicker = 0
        $eligiblePickerQueries = 0

        foreach ($entry in $script:Healed) {
            $entry.Result.Stats.ParametersPatched | Should -Be 0 -Because "$($entry.Name) must not rewrite customer parameters in self-healing mode"
            $parametersPatched += [int]$entry.Result.Stats.ParametersPatched
            $scopedViaPicker += [int]$entry.Result.Stats.ScopedViaPicker

            $before = ConvertFrom-SerializedWorkbook -Json $entry.Baseline
            $referencedPickers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($e in @(Get-WorkbookNode -Root $before)) {
                if (-not (Test-EligibleQueryNode -Node $e.Node)) { continue }
                if ((Get-ScopeReferenceKind -Node $e.Node) -eq 'Parameter') {
                    $eligiblePickerQueries++
                    $pickerName = Get-ReferencedParameterName -Node $e.Node
                    if ($pickerName) { [void]$referencedPickers.Add($pickerName) }
                }
            }

            foreach ($pickerName in @($referencedPickers)) {
                $beforeParameters = @(Get-WorkbookNode -Root $before |
                    Where-Object { (Test-IsParameterNode -Path $_.Path) -and [string]$_.Node['name'] -eq $pickerName } |
                    ForEach-Object { ConvertTo-Json $_.Node -Depth 100 -Compress })
                $afterParameters = @(Get-WorkbookNode -Root $entry.Root |
                    Where-Object { (Test-IsParameterNode -Path $_.Path) -and [string]$_.Node['name'] -eq $pickerName } |
                    ForEach-Object { ConvertTo-Json $_.Node -Depth 100 -Compress })

                @($afterParameters).Count | Should -Be @($beforeParameters).Count -Because "$($entry.Name) should keep each referenced customer picker"
                for ($i = 0; $i -lt @($beforeParameters).Count; $i++) {
                    $afterParameters[$i] | Should -BeExactly $beforeParameters[$i] -Because "$($entry.Name) must leave customer picker $pickerName unchanged"
                }
            }
        }

        $parametersPatched | Should -Be 0
        $scopedViaPicker | Should -BeGreaterThan 0
        $scopedViaPicker | Should -Be $eligiblePickerQueries
    }

    It 'is idempotent' {
        foreach ($entry in $script:Healed) {
            $again = ConvertFrom-SerializedWorkbook -Json $entry.Json
            $second = Set-WorkbookDualScope -Root $again `
                -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId `
                -ScopeMode SelfHealing -SourceSubscriptionId $script:SourceSub -DestinationSubscriptionId $script:DestSub
            $second.Action | Should -Be 'AlreadyScoped' -Because "$($entry.Name) was already scoped"
            (ConvertTo-SerializedWorkbook -Root $again) | Should -BeExactly $entry.Json
        }
    }

    It 'reverts byte-for-byte through the save and reload path' {
        foreach ($entry in $script:Healed) {
            $reloaded = ConvertFrom-SerializedWorkbook -Json $entry.Json
            $rev = Restore-WorkbookScope -Root $reloaded -SourceWorkspaceId $script:SourceId
            $rev.Method | Should -Be 'Manifest'
            (ConvertTo-SerializedWorkbook -Root $reloaded) | Should -BeExactly $entry.Baseline -Because "$($entry.Name) must revert exactly"
        }
    }

    It 'reverts by heuristic when the manifest has been lost' {
        # A portal re-save can drop the manifest. The heuristic must still remove
        # both the parameter and every reference to it.
        $entry = $script:Healed | Where-Object { $_.Result.Stats.Eligible -gt 0 } | Select-Object -First 1
        $root = ConvertFrom-SerializedWorkbook -Json $entry.Json
        Remove-DualScopeManifest -Root $root

        $rev = Restore-WorkbookScope -Root $root -SourceWorkspaceId $script:SourceId
        $rev.Method | Should -Be 'Heuristic'

        $out = ConvertTo-SerializedWorkbook -Root $root
        $out | Should -Not -Match ([regex]::Escape("{$($entry.ParamName)}"))
        Get-ScopeParameterItemIndex -Root $root | Should -Be -1
    }

    It 'avoids colliding with an existing parameter of the same name' {
        $json = '{"version":"Notebook/1.0","items":[{"type":9,"content":{"parameters":[{"id":"p1","version":"KqlParameterItem/1.0","name":"WBScopeSource","type":1}]},"name":"params"},{"type":3,"content":{"query":"Heartbeat","queryType":0},"name":"q1"}]}'
        $root = ConvertFrom-SerializedWorkbook -Json $json
        $null = Set-WorkbookDualScope -Root $root `
            -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId -ScopeMode SelfHealing
        [string](Get-DualScopeManifest -Root $root)['scopeParameterName'] | Should -Not -Be 'WBScopeSource'
    }

    It 're-scopes a workbook that was previously scoped in literal mode' {
        # Older runs left the fragile form behind. Re-running must migrate them
        # rather than reporting AlreadyScoped and leaving them broken-on-delete.
        $json = '{"version":"Notebook/1.0","items":[{"type":3,"content":{"query":"Heartbeat","queryType":0},"name":"q1"}]}'
        $root = ConvertFrom-SerializedWorkbook -Json $json
        $null = Set-WorkbookDualScope -Root $root `
            -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId -ScopeMode Literal
        $second = Set-WorkbookDualScope -Root $root `
            -SourceWorkspaceId $script:SourceId -DestinationWorkspaceId $script:DestId -ScopeMode SelfHealing
        $second.Action | Should -Be 'Scoped'
    }
}
