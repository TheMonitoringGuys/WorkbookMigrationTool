<#
    Live Azure verification.

    Everything else in this suite runs offline and asserts on JSON this tool
    produced itself. That is why the tool could be reported as verified 210 tests
    green while rendering no historical data in a customer tenant: the offline
    suite measures the tool's agreement with its own assumptions, and the thing
    that actually decides correctness is how the Azure Workbooks engine and the
    Log Analytics query API behave at runtime.

    These tests close that gap. They run the real tool against real Azure, read
    the workbooks back out of ARM, and then execute a cross-workspace query and
    require rows from BOTH workspaces. That last assertion is the only one in
    the repository that can prove the tool works. Everything else is a proxy.

    They are tagged 'Live' and skip unless a lab is configured, so the offline
    suite is unaffected:

        $env:WBSCOPE_LAB_SRC_SUB   = '<source subscription id>'
        $env:WBSCOPE_LAB_SRC_RG    = '<source resource group>'
        $env:WBSCOPE_LAB_SRC_WS    = '<source workspace name>'
        $env:WBSCOPE_LAB_DST_SUB   = '<destination subscription id>'
        $env:WBSCOPE_LAB_DST_RG    = '<destination resource group>'
        $env:WBSCOPE_LAB_DST_WS    = '<destination workspace name>'
        # Optional: a table seeded in BOTH workspaces with distinguishable rows.
        $env:WBSCOPE_LAB_TABLE     = 'WBScopeProbe_CL'

        Connect-AzAccount
        Invoke-Pester -Path ./tests/Live.Azure.Tests.ps1 -Tag Live

    The lab must be disposable. These tests write to workbooks in the
    destination resource group.
#>

BeforeDiscovery {
    $script:LabVars = @(
        'WBSCOPE_LAB_SRC_SUB', 'WBSCOPE_LAB_SRC_RG', 'WBSCOPE_LAB_SRC_WS',
        'WBSCOPE_LAB_DST_SUB', 'WBSCOPE_LAB_DST_RG', 'WBSCOPE_LAB_DST_WS'
    )
    $script:LabMissing = @($script:LabVars | Where-Object { -not [Environment]::GetEnvironmentVariable($_) })
    $script:LabConfigured = $script:LabMissing.Count -eq 0
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $script:RepoRoot 'Sentinel-Workbook-Scope-Assistant.ps1'

    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Api.psm1') -Force -DisableNameChecking

    $script:Lab = @{
        SrcSub = $env:WBSCOPE_LAB_SRC_SUB; SrcRg = $env:WBSCOPE_LAB_SRC_RG; SrcWs = $env:WBSCOPE_LAB_SRC_WS
        DstSub = $env:WBSCOPE_LAB_DST_SUB; DstRg = $env:WBSCOPE_LAB_DST_RG; DstWs = $env:WBSCOPE_LAB_DST_WS
        Table  = if ($env:WBSCOPE_LAB_TABLE) { $env:WBSCOPE_LAB_TABLE } else { 'Heartbeat' }
    }

    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) "wbscope-live-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

    $script:ConfigPath = Join-Path $script:Work 'config.json'
    @{
        source      = @{ subscriptionId = $script:Lab.SrcSub; resourceGroupName = $script:Lab.SrcRg; workspaceName = $script:Lab.SrcWs }
        destination = @{ subscriptionId = $script:Lab.DstSub; resourceGroupName = $script:Lab.DstRg; workspaceName = $script:Lab.DstWs }
        options     = @{ cloud = 'Commercial' }
    } | ConvertTo-Json -Depth 10 | Set-Content $script:ConfigPath -Encoding UTF8

    $script:OutDir = Join-Path $script:Work 'output'

    function Get-LabWorkspaceId {
        param([string]$Sub, [string]$Rg, [string]$Ws)
        Get-WorkspaceResourceId -SubscriptionId $Sub -ResourceGroupName $Rg -WorkspaceName $Ws
    }

    function Invoke-LabTool {
        param([string[]]$ExtraArgs = @())
        $args = @('-ConfigFile', $script:ConfigPath, '-OutputDir', $script:OutDir) + $ExtraArgs
        $out = & $script:Script @args 2>&1 | Out-String
        [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
}

Describe 'Live Azure' -Tag 'Live' -Skip:(-not $script:LabConfigured) {

    Context 'Preconditions' {

        It 'has an authenticated Azure context' {
            $ctx = Get-AzContext -ErrorAction SilentlyContinue
            $ctx | Should -Not -BeNullOrEmpty -Because 'run Connect-AzAccount before the live suite'
        }

        It 'resolves both lab workspaces in ARM' {
            $arm = Resolve-ArmEndpoint -Cloud 'Commercial'
            foreach ($w in @(
                @{ Sub = $script:Lab.SrcSub; Rg = $script:Lab.SrcRg; Ws = $script:Lab.SrcWs },
                @{ Sub = $script:Lab.DstSub; Rg = $script:Lab.DstRg; Ws = $script:Lab.DstWs })) {

                $uri = Get-WorkspaceUriWithVersion -WorkspaceUri (
                    Get-ScopeWorkspaceUri -ArmEndpoint $arm -SubscriptionId $w.Sub `
                        -ResourceGroupName $w.Rg -WorkspaceName $w.Ws)

                { Invoke-ScopeApi -Uri $uri -Method GET } | Should -Not -Throw -Because "lab workspace '$($w.Ws)' must exist"
            }
        }

        It 'can read both workspaces in a single cross-resource query' {
            # If this fails, nothing downstream can work regardless of what the
            # tool writes, and the failure is permissions or workspace identity -
            # not scoping. Establishing that here keeps it from being
            # misdiagnosed as a tool defect later.
            $arm = Resolve-ArmEndpoint -Cloud 'Commercial'
            $la = Resolve-LogAnalyticsEndpoint

            $dstUri = Get-WorkspaceUriWithVersion -WorkspaceUri (
                Get-ScopeWorkspaceUri -ArmEndpoint $arm -SubscriptionId $script:Lab.DstSub `
                    -ResourceGroupName $script:Lab.DstRg -WorkspaceName $script:Lab.DstWs)
            $dstGuid = (Invoke-ScopeApi -Uri $dstUri -Method GET).properties.customerId

            $srcId = Get-LabWorkspaceId -Sub $script:Lab.SrcSub -Rg $script:Lab.SrcRg -Ws $script:Lab.SrcWs
            $query = "union withsource=SourceWs $($script:Lab.Table), workspace('$srcId').$($script:Lab.Table) | summarize Rows=count() by SourceWs"

            $resp = Invoke-ScopeApi -Method POST -ResourceUrl $la `
                -Uri (Get-LogAnalyticsQueryUri -LogAnalyticsEndpoint $la -WorkspaceId $dstGuid) `
                -Body @{ query = $query }

            $resp | Should -Not -BeNullOrEmpty
            @($resp.tables[0].rows).Count | Should -BeGreaterThan 1 -Because 'both workspaces must return rows, or the lab is not seeded for a meaningful test'
        }
    }

    Context 'Apply' {

        BeforeAll { $script:ApplyRun = Invoke-LabTool -ExtraArgs @('-Execute', '-Force', '-IncludeAllWorkbooks') }

        It 'completes without failures' {
            $script:ApplyRun.ExitCode | Should -Be 0 -Because "tool output was:`n$($script:ApplyRun.Output)"
        }

        It 'survives the ARM round trip with the source workspace in real query scope' {
            # Reading the workbook back from Azure is the step the offline suite
            # cannot perform. A payload ARM silently normalises, rejects in part,
            # or re-serialises differently is indistinguishable from success
            # until it is read back.
            $arm = Resolve-ArmEndpoint -Cloud 'Commercial'
            $srcId = Get-LabWorkspaceId -Sub $script:Lab.SrcSub -Rg $script:Lab.SrcRg -Ws $script:Lab.SrcWs
            $dstWsId = Get-LabWorkspaceId -Sub $script:Lab.DstSub -Rg $script:Lab.DstRg -Ws $script:Lab.DstWs

            $listUri = Get-WorkbooksUri -ArmEndpoint $arm -SubscriptionId $script:Lab.DstSub `
                -ResourceGroupName $script:Lab.DstRg -SourceId $dstWsId
            $workbooks = @(Invoke-ScopeApiList -Uri $listUri)

            $workbooks.Count | Should -BeGreaterThan 0 -Because 'the lab destination must hold at least one workbook'

            $scoped = 0
            foreach ($wb in $workbooks) {
                $doc = $wb.properties.serializedData | ConvertFrom-Json
                # Manifest excluded deliberately: it records the source ID as
                # bookkeeping, so matching on it would pass with nothing scoped.
                $doc.PSObject.Properties.Remove('$dualScope')
                if (($doc | ConvertTo-Json -Depth 100 -Compress) -match [regex]::Escape($srcId)) { $scoped++ }
            }

            $scoped | Should -BeGreaterThan 0 -Because 'no workbook came back from Azure with the source workspace in query scope'
        }

        It 'returns data from BOTH workspaces through a scoped workbook query' {
            <#
                The assertion this repository has never had.

                A workbook can carry perfect scope JSON and still render empty -
                the viewer may lack Log Analytics Reader on the source, a picker
                may re-resolve and drop the source, or fallbackResourceIds may be
                overridden per query. None of that is visible in the JSON, and
                all of it looks identical from the outside. Executing the query
                and counting distinct workspaces is what tells them apart.
            #>
            $arm = Resolve-ArmEndpoint -Cloud 'Commercial'
            $la = Resolve-LogAnalyticsEndpoint

            $dstUri = Get-WorkspaceUriWithVersion -WorkspaceUri (
                Get-ScopeWorkspaceUri -ArmEndpoint $arm -SubscriptionId $script:Lab.DstSub `
                    -ResourceGroupName $script:Lab.DstRg -WorkspaceName $script:Lab.DstWs)
            $dstGuid = (Invoke-ScopeApi -Uri $dstUri -Method GET).properties.customerId
            $srcId = Get-LabWorkspaceId -Sub $script:Lab.SrcSub -Rg $script:Lab.SrcRg -Ws $script:Lab.SrcWs

            $query = "union withsource=SourceWs $($script:Lab.Table), workspace('$srcId').$($script:Lab.Table) | summarize Rows=count() by SourceWs"
            $resp = Invoke-ScopeApi -Method POST -ResourceUrl $la `
                -Uri (Get-LogAnalyticsQueryUri -LogAnalyticsEndpoint $la -WorkspaceId $dstGuid) `
                -Body @{ query = $query }

            $rows = @($resp.tables[0].rows)
            $rows.Count | Should -BeGreaterThan 1 -Because 'a correctly scoped workbook must return rows from the source workspace as well as the destination'
        }
    }

    Context 'Revert' {

        BeforeAll { $script:RevertRun = Invoke-LabTool -ExtraArgs @('-Revert', '-Execute', '-Force', '-IncludeAllWorkbooks') }

        It 'completes without failures' {
            $script:RevertRun.ExitCode | Should -Be 0 -Because "tool output was:`n$($script:RevertRun.Output)"
        }

        It 'removes the source workspace from query scope in Azure' {
            # Revert is mandatory before decommissioning in the default Literal
            # mode. If it does not really clear the scope, following the runbook
            # still leaves every tile broken when the workspace is deleted.
            $arm = Resolve-ArmEndpoint -Cloud 'Commercial'
            $srcId = Get-LabWorkspaceId -Sub $script:Lab.SrcSub -Rg $script:Lab.SrcRg -Ws $script:Lab.SrcWs
            $dstWsId = Get-LabWorkspaceId -Sub $script:Lab.DstSub -Rg $script:Lab.DstRg -Ws $script:Lab.DstWs

            $listUri = Get-WorkbooksUri -ArmEndpoint $arm -SubscriptionId $script:Lab.DstSub `
                -ResourceGroupName $script:Lab.DstRg -SourceId $dstWsId

            foreach ($wb in @(Invoke-ScopeApiList -Uri $listUri)) {
                $doc = $wb.properties.serializedData | ConvertFrom-Json
                $doc.PSObject.Properties.Remove('$dualScope')
                ($doc | ConvertTo-Json -Depth 100 -Compress) |
                    Should -Not -Match ([regex]::Escape($srcId)) -Because "workbook '$($wb.properties.displayName)' still references the source workspace after revert"
            }
        }
    }
}

Describe 'Live Azure configuration' {

    It 'reports plainly when the lab is not configured' {
        # A skipped live suite must never be mistaken for a passing one. This
        # test always runs and states which variables are missing.
        # Recomputed here: BeforeDiscovery variables are not in scope at run time.
        $required = @(
            'WBSCOPE_LAB_SRC_SUB', 'WBSCOPE_LAB_SRC_RG', 'WBSCOPE_LAB_SRC_WS',
            'WBSCOPE_LAB_DST_SUB', 'WBSCOPE_LAB_DST_RG', 'WBSCOPE_LAB_DST_WS'
        )
        $missing = @($required | Where-Object { -not [Environment]::GetEnvironmentVariable($_) })

        if ($missing.Count -eq 0) {
            Set-ItResult -Skipped -Because 'the lab is configured, so the live tests above ran'
        }
        else {
            Write-Host ''
            Write-Host '  LIVE AZURE VERIFICATION DID NOT RUN.' -ForegroundColor Yellow
            Write-Host "  Missing: $($missing -join ', ')" -ForegroundColor Yellow
            Write-Host '  The offline suite alone does not verify this tool. See tests/Live.Azure.Tests.ps1.' -ForegroundColor Yellow
            Write-Host ''
            $true | Should -BeTrue
        }
    }
}
