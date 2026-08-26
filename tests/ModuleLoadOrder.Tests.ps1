<#
    Regression test for the module load-order defect.

    Import-Module -Force removes a module before re-importing it, and every module
    in src/ self-imports its dependencies the same way. So importing Discovery -
    which imports Common and Api with -Force - unloads whatever copies the caller
    already had and rebinds those functions into Discovery's private scope.

    The orchestrator loaded Common, Api and Engine first, so by the end of its
    module block none of their functions were resolvable and the script died on
    the first call to Set-ScopeApiDefault. The fix is a trailing re-import of the
    base modules, deepest dependency first, so the shallowest has the final word.

    Unit tests cannot catch this: they import modules in their own correct order,
    so the orchestrator's ordering is never exercised. This test replays the
    orchestrator's actual sequence - parsed out of the script rather than
    hardcoded, so a module added later is covered automatically - and asserts
    that every function every module exports is still resolvable at the end.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $script:RepoRoot 'Sentinel-Workbook-Scope-Assistant.ps1'
    $script:SrcDir = Join-Path $script:RepoRoot 'src'

    # The module list the orchestrator iterates, in source order, including the
    # deliberate repeats at the tail.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
    $assignment = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$moduleLoadOrder'
        }, $true) | Select-Object -First 1

    $script:ImportOrder = @()
    if ($assignment) {
        $script:ImportOrder = @($assignment.Right.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
                }, $true) | ForEach-Object { $_.Value })
    }

    # Every function the modules advertise, collected in a pristine process so a
    # load-order problem here cannot corrupt the expectation itself.
    $script:AllExports = @(pwsh -NoProfile -NonInteractive -Command "
        `$all = @()
        Get-ChildItem '$($script:SrcDir -replace "'","''")\*.psm1' | ForEach-Object {
            `$m = Import-Module `$_.FullName -Force -DisableNameChecking -PassThru
            `$all += `$m.ExportedFunctions.Keys
            Remove-Module `$m -Force -ErrorAction SilentlyContinue
        }
        (`$all | Sort-Object -Unique) -join ','
    " | Out-String).Trim() -split ',' | Where-Object { $_ }
}

Describe 'Orchestrator module load order' {

    It 'parses a non-trivial import sequence out of the script' {
        # Guards the test itself: if the AST walk stops matching, every assertion
        # below would pass vacuously.
        $script:ImportOrder.Count | Should -BeGreaterThan 5
        $script:ImportOrder | Should -Contain 'Common'
        $script:ImportOrder | Should -Contain 'Engine'
    }

    It 'discovers the exported function surface' {
        $script:AllExports.Count | Should -BeGreaterThan 40
    }

    It 'leaves every exported function callable after the full import sequence' {
        $srcDir = $script:SrcDir
        $orderLit = ($script:ImportOrder | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ','
        $expectLit = ($script:AllExports | ForEach-Object { "'$_'" }) -join ','

        # A child process, because Import-Module -Force mutates session state and
        # this test is specifically about that mutation. It must not leak into the
        # rest of the suite.
        $result = pwsh -NoProfile -NonInteractive -Command "
            `$ErrorActionPreference = 'Stop'
            foreach (`$m in @($orderLit)) {
                Import-Module (Join-Path '$($srcDir -replace "'","''")' `"WorkbookScope.`$m.psm1`") -Force -DisableNameChecking
            }
            `$missing = @()
            foreach (`$fn in @($expectLit)) {
                if (-not (Get-Command `$fn -ErrorAction SilentlyContinue)) { `$missing += `$fn }
            }
            `$missing -join ','
        " 2>&1

        $missing = ($result | Out-String).Trim()
        $missing | Should -BeNullOrEmpty -Because "these functions were unloaded by a later Import-Module -Force, so the orchestrator cannot call them: $missing"
    }

    It 'ends with the base modules, shallowest last' {
        # The structural guarantee behind the assertion above, stated separately
        # so a failure points at the cause rather than the symptom. Common must
        # come last because both Engine and Api self-import it.
        $tail = @($script:ImportOrder | Select-Object -Last 3)
        $tail | Should -Be @('Engine', 'Api', 'Common') -Because 'any module imported after Common with -Force unloads it again'
    }
}
