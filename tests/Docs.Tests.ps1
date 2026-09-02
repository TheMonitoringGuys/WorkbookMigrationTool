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
        Recovery    = Join-Path $script:RepoRoot 'docs\recovery.md'
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

Describe 'Documented commands' {
    <#
        A command in the documentation that does not run is the same class of
        defect as a test that cannot fail: it looks like guidance and is not.
        Both of these have already happened here - a runbook naming the wrong
        default scope mode, and a push command naming a branch that did not
        exist.

        These tests check that every script the docs tell someone to run exists,
        and that every switch they pass it is real.
    #>

    BeforeAll {
        $script:DocFiles = @($script:Docs.Values | Where-Object { Test-Path $_ })

        function Get-ScriptParameterName {
            param([string]$Path)
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                (Resolve-Path $Path), [ref]$null, [ref]$errors)
            if (-not $ast.ParamBlock) { return @() }
            return @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        }
    }

    It 'references only scripts that exist' {
        $missing = foreach ($f in $script:DocFiles) {
            $lineNo = 0
            foreach ($line in (Get-Content $f)) {
                $lineNo++
                foreach ($m in [regex]::Matches($line, '\./(tools|tests)/[A-Za-z0-9\.\-]+\.ps1')) {
                    $rel = $m.Value -replace '^\./', '' -replace '/', [System.IO.Path]::DirectorySeparatorChar
                    if (-not (Test-Path (Join-Path $script:RepoRoot $rel))) {
                        "$(Split-Path $f -Leaf):$lineNo -> $($m.Value)"
                    }
                }
            }
        }

        $missing | Should -BeNullOrEmpty -Because 'a documented command that points at a missing script cannot be followed'
    }

    It 'passes only switches the target script actually declares' {
        # Scoped to the scripts the docs drive most, and skips parameters that
        # belong to a different command on the same line - Get-Help ... -Full is
        # the common one.
        $targets = @{
            'Sentinel-Workbook-Scope-Assistant.ps1' = (Get-ScriptParameterName (Join-Path $script:RepoRoot 'Sentinel-Workbook-Scope-Assistant.ps1'))
            'Test-WorkbookScope.ps1'                = (Get-ScriptParameterName (Join-Path $script:RepoRoot 'tools\Test-WorkbookScope.ps1'))
            'New-ScopeLab.ps1'                      = (Get-ScriptParameterName (Join-Path $script:RepoRoot 'tools\New-ScopeLab.ps1'))
            'Save-ArmFixture.ps1'                   = (Get-ScriptParameterName (Join-Path $script:RepoRoot 'tools\Save-ArmFixture.ps1'))
        }
        $common = @(
            'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'WhatIf', 'Confirm'
            'ErrorVariable', 'WarningVariable', 'OutVariable', 'OutBuffer'
            'PipelineVariable', 'InformationAction', 'InformationVariable', 'ProgressAction'
        )

        $bad = foreach ($f in $script:DocFiles) {
            $lineNo = 0
            foreach ($line in (Get-Content $f)) {
                $lineNo++
                # Another cmdlet on the line owns its own switches.
                if ($line -match '(?i)\bGet-Help\b') { continue }

                foreach ($name in $targets.Keys) {
                    if ($line -notmatch [regex]::Escape($name)) { continue }
                    foreach ($m in [regex]::Matches($line, '\s-([A-Za-z][A-Za-z0-9]*)')) {
                        $p = $m.Groups[1].Value
                        if ($p -in $common) { continue }
                        if ($p -notin $targets[$name]) {
                            "$(Split-Path $f -Leaf):$lineNo -$p is not a parameter of $name"
                        }
                    }
                }
            }
        }

        $bad | Should -BeNullOrEmpty -Because 'a documented switch the script does not declare fails at the prompt'
    }
}
