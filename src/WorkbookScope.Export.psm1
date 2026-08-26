Import-Module (Join-Path $PSScriptRoot 'WorkbookScope.Common.psm1') -Force -DisableNameChecking

function Write-ScopeExportLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug')]
        [string]$Level = 'Info'
    )
    Write-Host "[$Level] [Export] $Message"
}

function Get-ScopeProp {
    param([object]$Object, [Parameter(Mandatory)][string]$Path, [object]$Default = $null)
    $cur = $Object
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $cur) { return $Default }
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($seg)) { return $Default }
            $cur = $cur[$seg]
            continue
        }
        $member = $cur.PSObject.Properties[$seg]
        if ($null -eq $member) { return $Default }
        $cur = $member.Value
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function Join-ScopeValues {
    param([object]$Value, [string]$Separator = '; ')
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) { return (@($Value) -join $Separator) }
    return [string]$Value
}

function Get-SafeSnapshotName {
    param([Parameter(Mandatory)][string]$WorkbookId)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() + [char[]]@('/', '\')
    $name = $WorkbookId
    foreach ($ch in $invalid) { $name = $name.Replace([string]$ch, '_') }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'workbook' }
    return "$name.json"
}

function Get-SafeSheetName {
    param([Parameter(Mandatory)][string]$Name, [string]$Suffix = '')
    $clean = ($Name -replace '[:\\/?*\[\]]', '-').Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'Sheet' }
    $budget = 31 - $Suffix.Length
    if ($budget -lt 1) { $budget = 1 }
    if ($clean.Length -gt $budget) { $clean = $clean.Substring(0, $budget) }
    return ($clean.Trim() + $Suffix)
}

function Get-SafeTableName {
    param([Parameter(Mandatory)][string]$Name, [System.Collections.IDictionary]$Used)
    $clean = $Name -replace '[^A-Za-z0-9]', ''
    if (-not $clean) { $clean = 'Table' }
    if ($clean -match '^[0-9]') { $clean = "T$clean" }
    $candidate = $clean
    $n = 2
    while ($Used -and $Used.Contains($candidate)) { $candidate = "$clean$n"; $n++ }
    if ($Used) { $Used[$candidate] = $true }
    return $candidate
}

function Test-ExportModuleAvailable {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Module -ListAvailable -Name $Name)
}

function Save-WorkbookSnapshot {
    <#
    .SYNOPSIS
        Saves an untouched workbook serializedData snapshot for revert.
    .DESCRIPTION
        Writes the exact serializedData string to OutputPath\snapshots using a
        filesystem-safe workbook identifier. Existing snapshots are not overwritten.
    .PARAMETER OutputPath
        Run output directory.
    .PARAMETER WorkbookId
        Workbook identifier used to derive the snapshot file name.
    .PARAMETER SerializedData
        The untouched serializedData string read before any workbook edit.
    .OUTPUTS
        The full snapshot path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$WorkbookId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SerializedData
    )
    $dir = Join-Path $OutputPath 'snapshots'
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $path = Join-Path $dir (Get-SafeSnapshotName -WorkbookId $WorkbookId)
    if (Test-Path $path) { throw "Workbook snapshot already exists: $path" }
    $SerializedData | Set-Content -Path $path -Encoding UTF8 -NoNewline
    return $path
}

function Get-WorkbookSnapshot {
    <#
    .SYNOPSIS
        Reads a saved workbook serializedData snapshot.
    .DESCRIPTION
        Returns the exact snapshot string saved by Save-WorkbookSnapshot, or null
        when the snapshot file is absent.
    .PARAMETER OutputPath
        Run output directory.
    .PARAMETER WorkbookId
        Workbook identifier used to derive the snapshot file name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$WorkbookId
    )
    $path = Join-Path (Join-Path $OutputPath 'snapshots') (Get-SafeSnapshotName -WorkbookId $WorkbookId)
    if (-not (Test-Path $path)) { return $null }
    return (Get-Content -Path $path -Raw -Encoding UTF8)
}

function Save-RawJson {
    <#
    .SYNOPSIS
        Saves an object as pretty JSON under the run raw folder.
    .PARAMETER OutputPath
        Run output directory.
    .PARAMETER Name
        Base JSON file name without an extension.
    .PARAMETER InputObject
        Object to serialize.
    .OUTPUTS
        The full path to the written JSON file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(ValueFromPipeline)][AllowNull()][object]$InputObject
    )
    process {
        $rawDir = Join-Path $OutputPath 'raw'
        if (-not (Test-Path $rawDir)) { New-Item -Path $rawDir -ItemType Directory -Force | Out-Null }
        $safeName = ($Name -replace '[\\/:*?"<>|]', '-').Trim()
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'raw' }
        $path = Join-Path $rawDir "$safeName.json"
        $InputObject | ConvertTo-Json -Depth 50 | Set-Content -Path $path -Encoding UTF8
        return $path
    }
}

function ConvertTo-SummaryRows {
    param([Parameter(Mandatory)][object]$RunResult)
    $results = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Results'))
    $errors = @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Errors'))
    $countBy = {
        param($Pattern)
        @($results | Where-Object { (Get-NormalizedAction $_.Action) -match $Pattern }).Count
    }
    $pairs = [ordered]@{
        'Mode'                    = Get-ScopeProp $RunResult 'Mode' ''
        'Operation'               = Get-ScopeProp $RunResult 'Operation' ''
        'Started'                 = if (Get-ScopeProp $RunResult 'StartTime') { ([datetime](Get-ScopeProp $RunResult 'StartTime')).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        'Completed'               = if (Get-ScopeProp $RunResult 'EndTime') { ([datetime](Get-ScopeProp $RunResult 'EndTime')).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        'Duration'                = Format-RunDuration (Get-ScopeProp $RunResult 'Duration')
        'Tool Version'            = Get-ScopeProp $RunResult 'ToolVersion' ''
        'Source Subscription'     = Get-ScopeProp $RunResult 'Source.SubscriptionId' ''
        'Source Resource Group'   = Get-ScopeProp $RunResult 'Source.ResourceGroupName' ''
        'Source Workspace'        = Get-ScopeProp $RunResult 'Source.WorkspaceName' ''
        'Destination Subscription'= Get-ScopeProp $RunResult 'Destination.SubscriptionId' ''
        'Destination Resource Group' = Get-ScopeProp $RunResult 'Destination.ResourceGroupName' ''
        'Destination Workspace'   = Get-ScopeProp $RunResult 'Destination.WorkspaceName' ''
        'Preflight Passed'        = [bool](Get-ScopeProp $RunResult 'Preflight.Passed')
        'Cross Subscription'      = [bool](Get-ScopeProp $RunResult 'Preflight.CrossSubscription')
        'Cross Region'            = [bool](Get-ScopeProp $RunResult 'Preflight.CrossRegion')
        'Workbooks Processed'     = $results.Count
        'Scoped'                  = & $countBy '^Scoped$'
        'Reverted'                = & $countBy '^Reverted$'
        'Already Scoped'          = & $countBy '^AlreadyScoped$'
        'Not Scoped'              = & $countBy '^NotScoped$'
        'Skipped'                 = & $countBy '^Skipped$'
        'Failed'                  = & $countBy '^Failed$'
        'Eligible Queries'        = ($results | Measure-Object -Property Eligible -Sum).Sum
        'Ineligible Queries'      = ($results | Measure-Object -Property Ineligible -Sum).Sum
        'Parameters Patched'      = ($results | Measure-Object -Property ParametersPatched -Sum).Sum
        'Errors'                  = $errors.Count
    }
    foreach ($k in $pairs.Keys) { [PSCustomObject][ordered]@{ Property = $k; Value = $pairs[$k] } }
}

function ConvertTo-WorkbookRows {
    param([Parameter(Mandatory)][object]$RunResult)
    foreach ($r in @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Results'))) {
        [PSCustomObject][ordered]@{
            WorkbookId        = $r.WorkbookId
            DisplayName       = $r.DisplayName
            Action            = Get-NormalizedAction $r.Action
            ActionLabel       = Format-ActionLabel $r.Action
            RawAction         = $r.Action
            Method            = $r.Method
            Eligible          = $r.Eligible
            Ineligible        = $r.Ineligible
            Added             = $r.Added
            Replaced          = $r.Replaced
            ParametersPatched = $r.ParametersPatched
            FallbackUpdated   = $r.FallbackUpdated
            ParameterNames    = Join-ScopeValues $r.ParameterNames
            SnapshotPath      = $r.SnapshotPath
            Reason            = $r.Reason
        }
    }
}

function ConvertTo-ErrorRows {
    param([Parameter(Mandatory)][object]$RunResult)
    foreach ($e in @(ConvertTo-ItemList (Get-ScopeProp $RunResult 'Errors'))) {
        [PSCustomObject][ordered]@{
            Component   = $e.Component
            Message     = $e.Message
            Remediation = $e.Remediation
            Critical    = $e.Critical
        }
    }
}

function ConvertTo-ValidationRows {
    param([Parameter(Mandatory)][object]$RunResult)
    $validation = Get-ScopeProp $RunResult 'Validation'
    if (-not $validation) { return @() }
    [PSCustomObject][ordered]@{ Type = 'Summary'; DisplayName = ''; Table = ''; Detail = "CrossQueryOk=$([bool]$validation.CrossQueryOk); SourceTables=$(@(ConvertTo-ItemList $validation.SourceTables).Count); DestinationTables=$(@(ConvertTo-ItemList $validation.DestinationTables).Count)" }
    if ($validation.CrossQueryError) { [PSCustomObject][ordered]@{ Type = 'CrossQueryError'; DisplayName = ''; Table = ''; Detail = $validation.CrossQueryError } }
    foreach ($t in @(ConvertTo-ItemList $validation.OnlyInSource)) { [PSCustomObject][ordered]@{ Type = 'OnlyInSource'; DisplayName = ''; Table = $t; Detail = '' } }
    foreach ($t in @(ConvertTo-ItemList $validation.OnlyInDestination)) { [PSCustomObject][ordered]@{ Type = 'OnlyInDestination'; DisplayName = ''; Table = $t; Detail = '' } }
    foreach ($f in @(ConvertTo-ItemList $validation.WorkbookFindings)) {
        foreach ($t in @(ConvertTo-ItemList $f.MissingInDestination)) { [PSCustomObject][ordered]@{ Type = 'MissingInDestination'; DisplayName = $f.DisplayName; Table = $t; Detail = '' } }
        foreach ($t in @(ConvertTo-ItemList $f.MissingInSource)) { [PSCustomObject][ordered]@{ Type = 'MissingInSource'; DisplayName = $f.DisplayName; Table = $t; Detail = '' } }
    }
}

function New-ScopeSheets {
    param([Parameter(Mandatory)][object]$RunResult)
    $sheets = [ordered]@{
        'Summary'   = @(ConvertTo-SummaryRows -RunResult $RunResult)
        'Workbooks' = @(ConvertTo-WorkbookRows -RunResult $RunResult)
        'Errors'    = @(ConvertTo-ErrorRows -RunResult $RunResult)
    }
    if (Get-ScopeProp $RunResult 'Validation') {
        $sheets['Validation'] = @(ConvertTo-ValidationRows -RunResult $RunResult)
    }
    return $sheets
}

function Export-ScopeWorkbook {
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Sheets,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$FileName = 'Scope-Results.xlsx',
        [switch]$NoAutoInstall
    )
    if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
    $hasImportExcel = Test-ExportModuleAvailable -Name 'ImportExcel'
    if (-not $hasImportExcel -and $NoAutoInstall) {
        Write-ScopeExportLog -Level 'Warning' -Message 'ImportExcel not installed and -NoAutoInstall was specified; writing CSV instead.'
    }
    elseif (-not $hasImportExcel) {
        try {
            Write-ScopeExportLog -Message 'Installing ImportExcel module...'
            Install-Module -Name ImportExcel -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            $hasImportExcel = $true
        }
        catch {
            Write-ScopeExportLog -Level 'Warning' -Message "ImportExcel unavailable; falling back to CSV. ($($_.Exception.Message))"
        }
    }
    if ($hasImportExcel) {
        Import-Module ImportExcel -ErrorAction Stop
        $xlsxPath = Join-Path $OutputPath $FileName
        if (Test-Path $xlsxPath) { Remove-Item $xlsxPath -Force }
        $usedSheets = @{}
        $usedTables = @{}
        foreach ($sheet in @($Sheets.Keys)) {
            $name = Get-SafeSheetName -Name $sheet
            $n = 2
            while ($usedSheets.ContainsKey($name)) { $name = (Get-SafeSheetName -Name $sheet -Suffix " $n"); $n++ }
            $usedSheets[$name] = $true
            $rows = @($Sheets[$sheet])
            if ($rows.Count -eq 0) { $rows = @([PSCustomObject]@{ Note = 'No items found' }) }
            $rows | Export-Excel -Path $xlsxPath -WorksheetName $name -AutoSize -FreezeTopRow -BoldTopRow -TableName (Get-SafeTableName -Name $name -Used $usedTables)
        }
        Write-ScopeExportLog -Level 'Success' -Message "Results workbook: $xlsxPath"
        return $xlsxPath
    }
    else {
        $csvDir = Join-Path $OutputPath 'csv'
        if (-not (Test-Path $csvDir)) { New-Item -Path $csvDir -ItemType Directory -Force | Out-Null }
        $usedFiles = @{}
        foreach ($sheet in @($Sheets.Keys)) {
            $rows = @($Sheets[$sheet])
            $file = Get-SafeSheetName -Name $sheet
            $n = 2
            while ($usedFiles.ContainsKey($file)) { $file = (Get-SafeSheetName -Name $sheet -Suffix " $n"); $n++ }
            $usedFiles[$file] = $true
            $path = Join-Path $csvDir "$file.csv"
            if ($rows.Count -eq 0) {
                'Note' | Set-Content -Path $path -Encoding UTF8
                'No items found' | Add-Content -Path $path -Encoding UTF8
            }
            else {
                $rows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
            }
        }
        Write-ScopeExportLog -Level 'Success' -Message "Results CSVs: $csvDir"
        return $csvDir
    }
}

function Export-ScopeResult {
    <#
    .SYNOPSIS
        Exports workbook scope results to Excel or CSV.
    .DESCRIPTION
        Writes Scope-Results.xlsx when ImportExcel is available. If ImportExcel is
        missing, it attempts the same auto-install pattern as the migration tool
        unless -NoAutoInstall is specified, then falls back to one CSV per sheet.
    .PARAMETER RunResult
        The RunResult object produced by the workbook scope assistant.
    .PARAMETER OutputPath
        Directory where Scope-Results.xlsx or csv files should be written.
    .PARAMETER NoAutoInstall
        Suppresses automatic ImportExcel installation and writes CSV fallback files.
    .OUTPUTS
        The full XLSX path or the CSV directory path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$RunResult,
        [Parameter(Mandatory)][string]$OutputPath,
        [switch]$NoAutoInstall
    )
    $ordered = [System.Collections.Specialized.OrderedDictionary]::new()
    $sheets = New-ScopeSheets -RunResult $RunResult
    foreach ($key in @($sheets.Keys)) { $ordered[$key] = @($sheets[$key]) }
    return (Export-ScopeWorkbook -Sheets $ordered -OutputPath $OutputPath -NoAutoInstall:$NoAutoInstall)
}

Export-ModuleMember -Function @(
    'Save-WorkbookSnapshot'
    'Get-WorkbookSnapshot'
    'Export-ScopeResult'
    'Save-RawJson'
)
