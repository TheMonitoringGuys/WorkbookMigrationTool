<#
    Tests for shared workbook-scope helpers.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src\WorkbookScope.Common.psm1') -Force -DisableNameChecking

    function New-ApiError {
        param([string]$Body, [string]$Message = 'transport failed', [nullable[int]]$StatusCode)

        $exception = [System.Exception]::new($Message)
        if ($null -ne $StatusCode) {
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{ StatusCode = $StatusCode }) -Force
        }

        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'api', 'NotSpecified', $null)
        if ($null -ne $Body) { $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body) }
        return $record
    }
}

Describe 'Array normalization' {

    It 'turns null into an empty safe array' {
        @((ConvertTo-SafeArray $null)).Count | Should -Be 0
    }

    It 'turns a scalar into a one-item safe array' {
        $items = @(ConvertTo-SafeArray 'one')
        $items.Count | Should -Be 1
        $items[0] | Should -Be 'one'
    }

    It 'drops null entries from a safe array' {
        $items = @(ConvertTo-SafeArray -Value @($null, 'one', $null, 'two'))
        $items.Count | Should -Be 2
        $items | Should -Be @('one', 'two')
    }

    It 'turns null into an empty item list' {
        @((ConvertTo-ItemList $null)).Count | Should -Be 0
    }

    It 'turns a scalar into a one-item list' {
        $items = @(ConvertTo-ItemList 42)
        $items.Count | Should -Be 1
        $items[0] | Should -Be 42
    }

    It 'drops null entries from an item list' {
        $items = @(ConvertTo-ItemList -Value @('one', $null, 'two'))
        $items | Should -Be @('one', 'two')
    }
}

Describe 'Action display' {

    It 'normalizes dry-run actions and handles null' {
        Get-NormalizedAction 'WouldBeScoped' | Should -Be 'Scoped'
        Get-NormalizedAction 'Scoped' | Should -Be 'Scoped'
        Get-NormalizedAction $null | Should -Be ''
    }

    It 'formats dry-run and executed scope labels' {
        Format-ActionLabel 'WouldBeScoped' | Should -Be 'Would be scoped to both workspaces'
        Format-ActionLabel 'Scoped' | Should -Be 'Scoped to both workspaces'
    }

    It 'never returns the raw action as the label' {
        Format-ActionLabel 'WouldBeScoped' | Should -Not -Be 'WouldBeScoped'
    }

    It 'returns exactly one console color name for each action' {
        foreach ($verb in @('Scoped', 'WouldBeScoped', 'Reverted', 'WouldBeReverted', 'AlreadyScoped', 'WouldBeAlreadyScoped', 'NotScoped', 'WouldBeNotScoped', 'Skipped', 'WouldBeSkipped', 'Failed', 'WouldBeFailed', 'Other')) {
            $color = @(Get-ActionColor $verb)
            $color.Count | Should -Be 1 -Because "$verb must not fall through to multiple switch arms"
            [enum]::IsDefined([ConsoleColor], [string]$color[0]) | Should -BeTrue
        }
    }
}

Describe 'Duration formatting' {

    It 'shows days for a run longer than 24 hours' {
        Format-RunDuration ([TimeSpan]::FromHours(26)) | Should -Be '1d 02:00:00'
    }

    It 'returns N/A for non-TimeSpan input' {
        Format-RunDuration '00:01:00' | Should -Be 'N/A'
    }

    It 'does not round 90 minutes up to two hours' {
        Format-RunDuration ([TimeSpan]::FromMinutes(90)) | Should -Be '01:30:00'
    }
}

Describe 'API error formatting' {

    It 'extracts code and message from an ARM error body' {
        $err = New-ApiError -Body '{"error":{"code":"X","message":"Y"}}'
        Format-ApiErrorDetail -ErrorRecord $err | Should -Be 'X: Y'
    }

    It 'extracts code and message from a double-nested ARM error body' {
        $err = New-ApiError -Body '{"error":{"error":{"code":"Nested","message":"Deep message"}}}'
        Format-ApiErrorDetail -ErrorRecord $err | Should -Be 'Nested: Deep message'
    }

    It 'falls back to the exception message for non-JSON errors' {
        $err = New-ApiError -Body $null -Message 'plain failure'
        Format-ApiErrorDetail -ErrorRecord $err | Should -Be 'plain failure'
    }

    It 'truncates long details at the requested payload length' {
        $err = New-ApiError -Body ('a' * 20)
        Format-ApiErrorDetail -ErrorRecord $err -MaxLength 8 | Should -Be 'aaaaaaaa...'
    }

    It 'returns the status code when the response has one' {
        $err = New-ApiError -Body $null -StatusCode 403
        Get-ApiErrorStatusCode -ErrorRecord $err | Should -Be 403
    }

    It 'returns null when the error has no response' {
        $err = New-ApiError -Body $null
        Get-ApiErrorStatusCode -ErrorRecord $err | Should -BeNullOrEmpty
    }
}

Describe 'Safe collection invocation' {

    It 'returns scriptblock results as an array on success' {
        $sink = [System.Collections.Generic.List[object]]::new()
        $items = @(Invoke-SafeCollection -Name 'demo' -ErrorSink $sink -Action { 'a'; 'b' })

        $items | Should -Be @('a', 'b')
        $sink.Count | Should -Be 0
    }

    It 'returns an empty array and records one structured failure on error' {
        $sink = [System.Collections.Generic.List[object]]::new()
        $items = @(Invoke-SafeCollection -Name 'demo' -ErrorSink $sink -Remediation 'Try again' -Critical -Action { throw 'boom' } 3>$null)

        $items.Count | Should -Be 0
        $sink.Count | Should -Be 1
        $sink[0].Component | Should -Be 'demo'
        $sink[0].Message | Should -Match 'boom'
        $sink[0].Remediation | Should -Be 'Try again'
        $sink[0].Critical | Should -BeTrue
    }
}
