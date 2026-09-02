<#
    Documentation consistency tests.

    A README/runbook contradiction about the default scope mode is not cosmetic.
    In Literal mode -Revert is mandatory *before* the source workspace is deleted;
    in SelfHealing it is optional tidy-up. A runbook that names the wrong default
    tells a customer they may decommission without reverting, which kills every
    scoped tile in every migrated workbook.

    That contradiction shipped. These tests derive the default from the code and
    fail if any document disagrees, so it cannot ship again.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Config.psm1') -Force -DisableNameChecking

    $script:Docs = @{
        README      = Join-Path $script:RepoRoot 'README.md'
        Runbook     = Join-Path $script:RepoRoot 'docs\runbook.md'
        Guide       = Join-Path $script:RepoRoot 'docs\customer-guide.md'
        Troubleshoot = Join-Path $script:RepoRoot 'docs\troubleshooting.md'
    }

    # Ground truth: whatever the config layer actually defaults to.
    $script:CodeDefault = (ConvertTo-NormalizedConfig -RawConfig @{}).Options.ScopeMode
}

Describe 'Default scope mode' {

    It 'is defined by the config layer, not by prose' {
        $script:CodeDefault | Should -BeIn @('Literal', 'SelfHealing')
    }

    It 'is Literal, so revert is mandatory before decommissioning' {
        # If this is ever changed deliberately, every document below has to change
        # with it, and the decommissioning guidance has to be re-reviewed.
        $script:CodeDefault | Should -Be 'Literal'
    }

    It 'is not contradicted by any document claiming SelfHealing is the default' {
        $offenders = foreach ($name in $script:Docs.Keys) {
            $path = $script:Docs[$name]
            if (-not (Test-Path $path)) { continue }
            $lineNo = 0
            foreach ($line in (Get-Content $path)) {
                $lineNo++
                # "defaults to SelfHealing", "the default SelfHealing mode",
                # "Self-healing mode (the default)" and similar.
                if ($line -match '(?i)default[^.|]{0,40}self[- ]?healing' -or
                    $line -match '(?i)self[- ]?healing[^.|]{0,25}\(the default\)') {
                    "$name`:$lineNo`: $($line.Trim())"
                }
            }
        }

        $offenders | Should -BeNullOrEmpty -Because 'the code default is Literal; a document naming SelfHealing as the default tells customers they can decommission without reverting'
    }

    It 'is stated as the default in the runbook decommissioning section' {
        $runbook = Get-Content $script:Docs.Runbook -Raw
        $runbook | Should -Match '(?i)###\s+Literal mode \(the default\)'
    }

    It 'is stated as the default in the customer guide parameter table' {
        # Line-based: the parameter table row contains escaped pipes inside inline
        # code, which makes a single column-splitting regex fragile and unreadable.
        $row = Get-Content $script:Docs.Guide |
            Where-Object { $_ -match '(?i)^\|\s*`-ScopeMode' }

        $row | Should -Not -BeNullOrEmpty -Because 'the guide must document -ScopeMode'
        $row | Should -Match "(?i)Defaults to ``$($script:CodeDefault)``"
    }
}

Describe 'Verification claims' {
    <#
        The tool was repeatedly reported as verified while failing in the field.
        Documents must not claim live-tenant verification that the README's own
        "Known limitations" section denies.
    #>

    It 'does not claim self-healing was exercised against a live tenant' {
        $guide = Get-Content $script:Docs.Guide -Raw
        $guide | Should -Not -Match '(?i)Exercised against a live tenant \| Yes'
    }

    It 'keeps the README admission that self-healing is unverified live' {
        $readme = Get-Content $script:Docs.README -Raw
        $readme | Should -Match '(?i)not been verified against live Azure'
    }
}
