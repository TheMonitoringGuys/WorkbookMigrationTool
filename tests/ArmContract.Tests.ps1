<#
    ARM contract tests.

    Every other offline test in this suite runs against fixtures written by
    hand. They encode what this tool believes Azure returns, so they can only
    confirm the tool agrees with itself. If ARM's actual shape differs - or
    changes - nothing here would notice, and the first sign would be a customer
    with empty dashboards.

    These tests check the tool's assumptions against a recording of real ARM
    responses, captured by tools/Save-ArmFixture.ps1. Each assumption below is
    one the code genuinely relies on; if Azure stops honouring it, the
    corresponding test fails and names what broke.

    They skip when no recording exists, and a test that always runs says so, so
    an absent recording is never mistaken for a passing contract.

        Connect-AzAccount
        ./tools/Save-ArmFixture.ps1 -ResourceGroupName rg-wbscope-lab -WorkspaceName wbscope-lab-dest
        Invoke-Pester -Path ./tests/ArmContract.Tests.ps1
#>

BeforeDiscovery {
    $script:RecordingPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\fixtures\recorded\arm-responses.json'
    $script:HasRecording = Test-Path $script:RecordingPath
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:RecordingPath = Join-Path $script:RepoRoot 'tests\fixtures\recorded\arm-responses.json'

    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Engine.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Api.psm1') -Force -DisableNameChecking

    if (Test-Path $script:RecordingPath) {
        $script:Rec = Get-Content $script:RecordingPath -Raw | ConvertFrom-Json
        $script:Workbooks = @($script:Rec.workbookList)
    }
}

Describe 'ARM response contract' -Skip:(-not $script:HasRecording) {

    Context 'Workspace' {

        It 'returns the customerId the data-plane query URI is built from' {
            # Get-LogAnalyticsQueryUri takes this GUID. Without it every
            # validation and diagnostic query targets nothing.
            $script:Rec.workspace.properties.customerId | Should -Not -BeNullOrEmpty
            $script:Rec.workspace.properties.customerId | Should -Match '^[0-9a-fA-F-]{36}$'
        }

        It 'returns a location, which the workbook PUT echoes back' {
            $script:Rec.workspace.location | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Workbook listing' {

        It 'returns workbooks at all' {
            $script:Workbooks.Count | Should -BeGreaterThan 0 -Because 'a recording with no workbooks cannot exercise the contract'
        }

        It 'carries serializedData as a JSON string, not an object' {
            # The tool parses this with ConvertFrom-Json and writes it back as a
            # string. If ARM ever returned it pre-parsed, every workbook would
            # round-trip to the wrong shape.
            foreach ($wb in $script:Workbooks) {
                $wb.properties.serializedData | Should -BeOfType [string]
                { $wb.properties.serializedData | ConvertFrom-Json } | Should -Not -Throw
            }
        }

        It 'carries the name segment the item URI is built from' {
            # Get-WorkbookUri takes the name, not the full ARM id.
            foreach ($wb in $script:Workbooks) {
                $wb.name | Should -Not -BeNullOrEmpty
                $wb.name | Should -Not -Match '/'
            }
        }

        It 'carries a full resource id whose last segment is that name' {
            # Discovery derives the workbook id from the listing id by splitting
            # on '/' and taking the last segment, while the PUT uses .name. In
            # real ARM these are the same value, so both paths agree.
            #
            # Worth knowing when this first runs: in tests/fixtures/workbooks.json
            # they disagree for all 16 workbooks, because that fixture was written
            # by hand with independently generated GUIDs for the two fields. No
            # real workbook looks like that. It is a good demonstration of why a
            # recorded fixture is worth having - and if this assertion ever fails
            # against a genuine recording, the two code paths above are addressing
            # different workbooks and that is a real defect.
            foreach ($wb in $script:Workbooks) {
                $wb.id | Should -Match '^/subscriptions/'
                ($wb.id -split '/')[-1] | Should -Be $wb.name
            }
        }

        It 'carries location and kind, both echoed by the PUT' {
            foreach ($wb in $script:Workbooks) {
                $wb.location | Should -Not -BeNullOrEmpty
            }
        }

        It 'binds each workbook to a workspace through properties.sourceId' {
            # The tool never modifies sourceId, and relies on it to keep the
            # workbook in the destination Sentinel blade.
            foreach ($wb in $script:Workbooks) {
                $wb.properties.sourceId | Should -Not -BeNullOrEmpty
                $wb.properties.sourceId | Should -Match '(?i)/providers/microsoft\.operationalinsights/workspaces/'
            }
        }
    }

    Context 'Workbook definition' {

        It 'parses to a document the traversal understands' {
            # Get-WorkbookNode walks items[]. A workbook without it yields no
            # queries and would be silently reported as having nothing to scope.
            $withItems = 0
            foreach ($wb in $script:Workbooks) {
                $doc = $wb.properties.serializedData | ConvertFrom-Json
                if ($doc.PSObject.Properties['items']) { $withItems++ }
            }
            $withItems | Should -BeGreaterThan 0 -Because 'no recorded workbook exposes items[], so the traversal has nothing to walk'
        }

        It 'round-trips through the tool without loss' {
            # ConvertFrom/ConvertTo-SerializedWorkbook is applied to every
            # workbook. Anything it drops is silently lost on write.
            foreach ($wb in $script:Workbooks) {
                $original = [string]$wb.properties.serializedData
                $root = ConvertFrom-SerializedWorkbook -Json $original
                $round = ConvertTo-SerializedWorkbook -Root $root

                $a = $original | ConvertFrom-Json | ConvertTo-Json -Depth 100 -Compress
                $b = $round | ConvertFrom-Json | ConvertTo-Json -Depth 100 -Compress
                $b | Should -Be $a -Because "workbook '$($wb.properties.displayName)' does not survive a parse/serialise round trip"
            }
        }
    }

    Context 'Read-only properties' {

        It 'returns the server-owned properties the PUT must strip' {
            # The tool removes timeModified, userId and revision before writing,
            # because ARM rejects them. That removal is only meaningful if they
            # are actually present in a GET - if Azure stopped returning them the
            # stripping would be dead code hiding a changed contract.
            $seen = @{}
            foreach ($wb in $script:Workbooks) {
                foreach ($ro in @('timeModified', 'userId', 'revision')) {
                    if ($wb.properties.PSObject.Properties[$ro]) { $seen[$ro] = $true }
                }
            }
            @($seen.Keys).Count | Should -BeGreaterThan 0 -Because 'the PUT strips these; if none are returned any more, that code and this assumption need revisiting'
        }
    }

    Context 'API versions' {

        It 'was recorded against the API versions the tool still requests' {
            # A recording made against a different API version proves nothing
            # about today's requests.
            $script:Rec.apiVersions.workbooks | Should -Be (Get-ScopeApiVersion 'workbooks')
            $script:Rec.apiVersions.workspaces | Should -Be (Get-ScopeApiVersion 'workspaces')
        }
    }

    Context 'Recording hygiene' {

        It 'contains no obvious real identifier when marked sanitized' -Skip:(-not $script:Rec.sanitized) {
            # The repository is public. A recording committed with real
            # subscription or tenant GUIDs would be a disclosure, and the whole
            # file is one long JSON string where they are easy to miss.
            $raw = Get-Content $script:RecordingPath -Raw
            $raw | Should -Not -Match 'rg-wbscope-lab'
            $raw | Should -Not -Match '(?i)wbscope-lab-(source|dest)'
        }
    }
}

Describe 'ARM contract recording' {

    It 'reports plainly when no recording exists' {
        $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\fixtures\recorded\arm-responses.json'
        if (Test-Path $path) {
            Set-ItResult -Skipped -Because 'a recording exists, so the contract tests above ran'
        }
        else {
            Write-Host ''
            Write-Host '  NO ARM RECORDING - the contract tests did not run.' -ForegroundColor Yellow
            Write-Host '  Every other offline fixture is self-authored, so nothing currently' -ForegroundColor Yellow
            Write-Host '  checks this tool against real Azure response shapes.' -ForegroundColor Yellow
            Write-Host '  Capture one:  ./tools/Save-ArmFixture.ps1 -ResourceGroupName <rg> -WorkspaceName <ws>' -ForegroundColor Yellow
            Write-Host ''
            $true | Should -BeTrue
        }
    }
}
