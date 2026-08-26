# Troubleshooting

## Common issues

### Workbook renders empty after scoping

**Cause:** The viewer does not have Log Analytics data-plane read access on the source
workspace. Updating a workbook is an ARM operation. Rendering the workbook is a Log
Analytics query operation. Those are separate permissions.

**Fix:** Assign **Log Analytics Reader** on both workspaces to every user who views the
workbook. The required action is
`Microsoft.OperationalInsights/workspaces/query/*/read`. Reopen the workbook after the
role assignment has propagated.

This is the first thing to check when the run succeeded but the dashboard is blank.

### "No workbooks matched"

**Cause:** By default the tool only scopes workbooks tagged `MigratedFromWorkbookId`,
which are the workbooks created by the Sentinel Migration Assistant. The migration may
not have created workbooks, the destination may be wrong, or `-WorkbookFilter` may be
too narrow.

**Fix:** Check the destination workspace and resource group. Remove or widen
`-WorkbookFilter`. If you deliberately want every Sentinel workbook in the destination
resource group, re-run with `-IncludeAllWorkbooks`.

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -DryRun -IncludeAllWorkbooks
```

Use that switch carefully. Workbooks installed by a Content Hub solution can be
reverted by a later solution update.

### Workspace picker does not list the source workspace

**Cause:** Workbook workspace picker parameters often query Azure Resource Graph scoped
to `{Subscription}`. In a cross-subscription migration, that picker can only list the
destination subscription, so the source workspace does not appear.

**Fix:** Re-run the scope tool. The engine widens parameter picker scope automatically
when the source and destination subscriptions differ. Preflight reports this as a
warning. If a workbook was edited by hand afterwards, re-run the tool to restore the
parameter patch.

### Dashboards are slow after scoping

**Cause:** Source and destination workspaces are in different regions. Cross-resource
queries must serialise and move intermediate data between regions before the workbook
can render.

**Fix:** This is expected for cross-region reads. Preflight warns but does not block.
Reduce the workbook time range, simplify expensive tiles, or plan a shorter dual-scope
period before decommissioning the source workspace.

### Partial results or missing rows

**Cause:** Some tables exist in only one workspace. Dual scope unions query results,
but it cannot make absent tables appear. A tile may show less history for tables that
were never collected in the source, or no recent data for tables not yet connected in
the destination.

**Fix:** Run with `-ValidateQueries` and review the Validation section. It lists tables
seen only in source and only in destination over the lookback window.

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute -ValidateQueries
```

Connect the missing data source, adjust the workbook expectation, or accept that the
history genuinely exists in only one workspace.

### Revert fell back to the heuristic

**Cause:** The run could not use a snapshot and could not find the embedded
`$dualScope` manifest. This can happen when the original run folder is unavailable and
the workbook was edited and saved in the Azure portal, whose re-serialization may drop
unknown embedded metadata.

**Fix:** If you still have the run folder that applied scope, re-run revert with
`-SnapshotPath` pointing at it. Otherwise review the workbook after heuristic revert.
The heuristic strips the source workspace ID from scope lists, which restores
destination-only reads in practice, but it cannot prove which arrays this tool created.

### HTTP 403 or access denied reading a workspace

**Cause:** The signed-in identity cannot read the source or destination workspace
through ARM, or cannot write workbooks to the destination resource group.

**Fix:** The operator needs read access on the source and Microsoft Sentinel
Contributor, or equivalent workbook write access, on the destination resource group.
Then reconnect and re-run.

### YAML config cannot be read

**Cause:** YAML parsing needs `powershell-yaml`. The tool installs it to CurrentUser
unless `-NoAutoInstall` is passed. Locked-down machines or build agents may block
PowerShell Gallery access.

**Fix:** Install the module manually, allow the automatic install, or use JSON config.
JSON is parsed by PowerShell itself and needs no extra module.

```powershell
Install-Module -Name powershell-yaml -Scope CurrentUser -Force
```

## JSON config example

Use this when you cannot install `powershell-yaml`. Do not rename YAML to `.json`; the
content has to be JSON.

```json
{
  "source": {
    "subscriptionId": "aaaa-bbbb-cccc-dddd",
    "resourceGroupName": "rg-sentinel-old",
    "workspaceName": "law-sentinel-old"
  },
  "destination": {
    "subscriptionId": "eeee-ffff-0000-1111",
    "resourceGroupName": "rg-sentinel-new",
    "workspaceName": "law-sentinel-new"
  },
  "options": {
    "dryRun": true,
    "cloud": "Commercial",
    "revert": false,
    "validateQueries": false,
    "lookbackDays": 7,
    "includeAllWorkbooks": false,
    "workbookFilter": "",
    "retryCount": 3,
    "throttleMs": 100
  }
}
```

An existing Sentinel Migration Assistant config can also be used as JSON. Its `target`
section is accepted as this tool's `destination` section.

## Diagnostic steps

### Enable verbose output

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -DryRun -Verbose
```

### Open the latest report

```powershell
$run = Get-ChildItem ./output -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Start-Process (Join-Path $run.FullName 'Scope-Summary.html')
```

### Inspect raw results

```powershell
$run = Get-ChildItem ./output -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$result = Get-Content (Join-Path $run.FullName 'raw/RunResult.json') -Raw | ConvertFrom-Json
$result.Results | Format-Table DisplayName, Action, Eligible, Added, Replaced, ParametersPatched, Reason
```

### Confirm the snapshot exists

```powershell
$run = Get-ChildItem ./output -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-ChildItem (Join-Path $run.FullName 'snapshots')
```
