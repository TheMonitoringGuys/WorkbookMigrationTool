<#
    Tests for configuration loading and parameter merging.

    The regression that matters most here is the empty-string override: an
    unbound [string] parameter in PowerShell is '' rather than $null, so passing
    the whole parameter set to Merge-ParameterOverrides unfiltered overwrote
    every value just read from the config file. It surfaced as a validation
    failure on options.cloud and would have silently blanked the workspace names.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Config.psm1') -Force -DisableNameChecking

    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "wbscope-cfg-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    function New-ConfigFile {
        param([string]$Content, [string]$Extension = '.json')
        $path = Join-Path $script:TempDir "cfg-$([guid]::NewGuid().ToString('N'))$Extension"
        Set-Content -Path $path -Value $Content -Encoding UTF8
        return $path
    }

    $script:ValidJson = @'
{
  "source":      { "subscriptionId": "sub-a", "resourceGroupName": "rg-a", "workspaceName": "ws-a" },
  "destination": { "subscriptionId": "sub-b", "resourceGroupName": "rg-b", "workspaceName": "ws-b" },
  "options":     { "cloud": "Commercial", "throttleMs": 250 }
}
'@
}

AfterAll {
    Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Config format detection' {

    It 'treats a .json extension as JSON' {
        Test-ConfigIsJson -Path 'c:\x\config.json' -Content '{}' | Should -BeTrue
    }

    It 'sniffs a JSON document saved with a .yml extension' {
        # JSON is a subset of YAML but not the reverse, so guessing towards JSON
        # is the safe direction.
        Test-ConfigIsJson -Path 'c:\x\config.yml' -Content '  { "a": 1 }' | Should -BeTrue
    }

    It 'treats real YAML as YAML' {
        Test-ConfigIsJson -Path 'c:\x\config.yml' -Content "source:`n  workspaceName: ws" | Should -BeFalse
    }
}

Describe 'Reading configuration' {

    It 'loads a JSON config without any third-party module' {
        $path = New-ConfigFile -Content $script:ValidJson
        $cfg = Read-ScopeConfig -Path $path

        $cfg.Source.SubscriptionId | Should -Be 'sub-a'
        $cfg.Destination.WorkspaceName | Should -Be 'ws-b'
        $cfg.Options.ThrottleMs | Should -Be 250
    }

    It "accepts 'target' as an alias for 'destination'" {
        # A config file written for the Sentinel Migration Assistant must work
        # here unchanged, so the workspace IDs never have to be retyped.
        $path = New-ConfigFile -Content @'
{
  "source": { "subscriptionId": "sub-a", "resourceGroupName": "rg-a", "workspaceName": "ws-a" },
  "target": { "subscriptionId": "sub-b", "resourceGroupName": "rg-b", "workspaceName": "ws-b" }
}
'@
        $cfg = Read-ScopeConfig -Path $path
        $cfg.Destination.WorkspaceName | Should -Be 'ws-b'
    }

    It 'defaults to a dry run' {
        $path = New-ConfigFile -Content $script:ValidJson
        (Read-ScopeConfig -Path $path).Options.DryRun | Should -BeTrue
    }

    It 'reports a missing file clearly' {
        { Read-ScopeConfig -Path (Join-Path $script:TempDir 'nope.json') } | Should -Throw '*not found*'
    }

    It 'reports an empty file clearly' {
        $path = New-ConfigFile -Content '   '
        { Read-ScopeConfig -Path $path } | Should -Throw '*empty*'
    }

    It 'reports malformed JSON clearly' {
        $path = New-ConfigFile -Content '{ "source": '
        { Read-ScopeConfig -Path $path } | Should -Throw '*JSON*'
    }
}

Describe 'Merging parameter overrides' {

    BeforeEach {
        $script:Cfg = ConvertTo-NormalizedConfig -RawConfig ($script:ValidJson | ConvertFrom-Json)
    }

    It 'applies a supplied override' {
        $merged = Merge-ParameterOverrides -Config $script:Cfg -Overrides @{ SourceWorkspace = 'ws-override' }
        $merged.Source.WorkspaceName | Should -Be 'ws-override'
    }

    It 'ignores an empty string rather than blanking a configured value' {
        # An unbound [string] parameter is '' not $null. Treating it as an
        # override wiped every value the config file supplied - it failed loudly
        # on cloud and would have failed silently on the workspace names.
        $merged = Merge-ParameterOverrides -Config $script:Cfg -Overrides @{
            SourceWorkspace = ''
            Cloud           = ''
        }
        $merged.Source.WorkspaceName | Should -Be 'ws-a'
        $merged.Options.Cloud | Should -Be 'Commercial'
    }

    It 'ignores a null override' {
        $merged = Merge-ParameterOverrides -Config $script:Cfg -Overrides @{ SourceWorkspace = $null }
        $merged.Source.WorkspaceName | Should -Be 'ws-a'
    }

    It 'still applies a $false switch, which is meaningful' {
        $script:Cfg.Options.Revert = $true
        $merged = Merge-ParameterOverrides -Config $script:Cfg -Overrides @{ Revert = $false }
        $merged.Options.Revert | Should -BeFalse
    }
}

Describe 'Validating configuration' {

    It 'accepts a complete configuration' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ($script:ValidJson | ConvertFrom-Json)
        { Assert-ConfigValid -Config $cfg } | Should -Not -Throw
    }

    It 'names every missing required field at once' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ([PSCustomObject]@{})
        { Assert-ConfigValid -Config $cfg } | Should -Throw '*source.subscriptionId*'
    }

    It 'rejects scoping a workspace to itself' {
        # A no-op that would still rewrite every workbook.
        $cfg = ConvertTo-NormalizedConfig -RawConfig ('{
          "source":      { "subscriptionId": "s", "resourceGroupName": "r", "workspaceName": "w" },
          "destination": { "subscriptionId": "s", "resourceGroupName": "r", "workspaceName": "w" }
        }' | ConvertFrom-Json)
        { Assert-ConfigValid -Config $cfg } | Should -Throw '*same workspace*'
    }

    It 'rejects an out-of-range retryCount and throttleMs' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ($script:ValidJson | ConvertFrom-Json)
        $cfg.Options.RetryCount = 99
        { Assert-ConfigValid -Config $cfg } | Should -Throw '*retryCount*'

        $cfg2 = ConvertTo-NormalizedConfig -RawConfig ($script:ValidJson | ConvertFrom-Json)
        $cfg2.Options.ThrottleMs = 99999
        { Assert-ConfigValid -Config $cfg2 } | Should -Throw '*throttleMs*'
    }

    It 'rejects an unknown cloud' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ($script:ValidJson | ConvertFrom-Json)
        $cfg.Options.Cloud = 'Mars'
        { Assert-ConfigValid -Config $cfg } | Should -Throw '*cloud*'
    }

    It 'rejects an unknown scope mode' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ($script:ValidJson | ConvertFrom-Json)
        $cfg.Options.ScopeMode = 'Magic'
        { Assert-ConfigValid -Config $cfg } | Should -Throw '*scopeMode*'
    }
}

Describe 'Scope mode' {

    It 'defaults to Literal' {
        # SelfHealing was the default until a customer hit HTTP 502 on every
        # workbook: its Resource Graph parameter runs in the viewer's context and
        # needs subscription-scope read, which Log Analytics Reader at workspace
        # scope does not grant. Literal depends on nothing beyond the workspaces.
        $cfg = ConvertTo-NormalizedConfig -RawConfig ($script:ValidJson | ConvertFrom-Json)
        $cfg.Options.ScopeMode | Should -Be 'Literal'
    }

    It 'reads scopeMode from the config file' {
        $path = New-ConfigFile -Content @'
{
  "source":      { "subscriptionId": "sub-a", "resourceGroupName": "rg-a", "workspaceName": "ws-a" },
  "destination": { "subscriptionId": "sub-b", "resourceGroupName": "rg-b", "workspaceName": "ws-b" },
  "options":     { "scopeMode": "SelfHealing" }
}
'@
        (Read-ScopeConfig -Path $path).Options.ScopeMode | Should -Be 'SelfHealing'
    }

    It 'accepts a command-line override' {
        $cfg = ConvertTo-NormalizedConfig -RawConfig ($script:ValidJson | ConvertFrom-Json)
        $merged = Merge-ParameterOverrides -Config $cfg -Overrides @{ ScopeMode = 'SelfHealing' }
        $merged.Options.ScopeMode | Should -Be 'SelfHealing'
    }

    It 'accepts both valid modes' {
        foreach ($mode in @('SelfHealing', 'Literal')) {
            $cfg = ConvertTo-NormalizedConfig -RawConfig ($script:ValidJson | ConvertFrom-Json)
            $cfg.Options.ScopeMode = $mode
            { Assert-ConfigValid -Config $cfg } | Should -Not -Throw
        }
    }
}

Describe 'Reading values from either parser shape' {

    It 'reads from a PSCustomObject, as ConvertFrom-Json produces' {
        $node = [PSCustomObject]@{ workspaceName = 'ws' }
        Get-ConfigValue -Node $node -Key 'workspaceName' | Should -Be 'ws'
    }

    It 'reads from a hashtable, as ConvertFrom-Yaml produces' {
        # Property access works on one shape and not the other, so every read
        # goes through Get-ConfigValue rather than assuming.
        $node = @{ workspaceName = 'ws' }
        Get-ConfigValue -Node $node -Key 'workspaceName' | Should -Be 'ws'
    }

    It 'returns null for an absent key or a null node' {
        Get-ConfigValue -Node ([PSCustomObject]@{}) -Key 'nope' | Should -BeNullOrEmpty
        Get-ConfigValue -Node $null -Key 'nope' | Should -BeNullOrEmpty
    }
}
