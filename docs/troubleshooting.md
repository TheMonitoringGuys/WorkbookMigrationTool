# Troubleshooting

## Common issues

### HTTP 502 "check the value of Authorization header"

Two unrelated problems produce this same message. **Work out which one you have before
changing anything** - the fixes have nothing in common, and the wording of the error
misleads in both cases.

| Where you saw it | Which problem |
|---|---|
| The tool stopped, with a line starting `Could not complete:` | The tool could not authenticate. See below. |
| A workbook failed to render in the Azure portal | A viewer permissions problem. See the next section. |

The deciding question is whether the run finished. If the tool exited with an error,
no workbook was touched, and the workbooks in the portal are exactly as they were.

#### A. The tool fails during a run

```
Could not complete: HTTP 502 on GET https://management.azure.com/subscriptions/.../
providers/Microsoft.Insights/workbooks?category=sentinel... - Forbidden:
Authentication information is not given in the correct format. Check the value of
Authorization header.
```

**This is not a permissions problem**, despite the word *Forbidden*. Azure is saying the
`Authorization` header it received was malformed, so the request never reached the point
of checking access. Granting roles will not help. The cause is on the machine running
the tool: `Get-AzAccessToken` returned something that could not be used as a bearer
token.

Three causes, in rough order of likelihood:

1. **The Azure session expired.** Most common with `Connect-AzAccount -UseDeviceAuth`,
   where silent refresh is more fragile. The token comes back empty and the header is
   the bare word `Bearer`.
2. **More than one Azure context is loaded.** `Get-AzAccessToken` returns more than one
   object, and the header ends up holding two tokens separated by a space.
3. **An outdated Az.Accounts.** Az.Accounts 5.x returns the token as a `SecureString`.
   An old or half-upgraded install can return a shape the tool cannot convert.

**Diagnose it.** This reports which of the three you have, and performs the exact call
that failed. It prints no token material and only reads:

```powershell
./tools/Test-ScopeConnection.ps1 `
    -SubscriptionId <destination-sub> `
    -ResourceGroupName <destination-rg> `
    -WorkspaceName <destination-workspace>
```

**Fix, in order:**

```powershell
Disconnect-AzAccount
Connect-AzAccount -UseDeviceAuth          # or plain Connect-AzAccount

Get-AzContext -ListAvailable              # if more than one is listed:
Set-AzContext -Subscription <destination-sub>

Update-Module Az.Accounts                 # if the version is below 2.19
```

If the diagnostic reports every token check passing and Azure *still* rejects the
header, the request is being altered in transit. That means an inspecting proxy, TLS
interception, or a gateway stripping the header. Ask whoever runs the network whether
`management.azure.com` is intercepted, and try from a machine outside that path.

From version 1.2.2 the tool checks the token before sending it, so this now fails
immediately with a message naming the cause instead of a 502 after three retries.

#### B. A workbook fails to render in the portal

**Cause:** The workbook is running an Azure Resource Graph query that the viewer is
not allowed to make. Resource Graph runs in the *viewer's* security context, and the
scope parameter this tool injects in `SelfHealing` mode is scoped to the source
**subscription**. A viewer without read access at subscription scope gets a 502 whose
message points at the authorization header, which reads like a sign-in problem and is
not one.

Log Analytics Reader granted at *workspace* scope is not sufficient. Resource Graph
needs read at the subscription that owns the workspace.

Because the injected parameter is marked global, it is evaluated on every workbook
load, so this takes the whole workbook down rather than a single tile.

This only affects workbooks scoped with `-ScopeMode SelfHealing`. Literal mode issues
no Resource Graph query at all, which is why the Sentinel Migration Assistant never
produced this error.

**Fix:** Re-run in literal mode, which is the default. A single run is enough: it
removes the injected parameter, clears every reference to it, and re-scopes with
literal resource IDs.

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -DryRun
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute
```

**Upgrading alone is not enough.** Versions 1.1.0 and 1.2.0 changed the default but
left the injected parameter in the workbook when re-scoping, so the run reported
success while the 502 carried on. Use 1.2.1 or later.

To confirm a workbook is clean, open it in the portal, choose Edit then Advanced
Editor, and search for `WBScopeSource`. A repaired workbook has no match.

Remember that literal scope must be reverted before the source workspace is
decommissioned.

To keep self-healing, grant every viewer **Reader on the source subscription** (not
just the workspace) and confirm with `-ValidateQueries`, which resolves the parameter
query as the running identity and reports when it comes back empty or denied.

### Signing in with device code authentication

Some tenants require `Connect-AzAccount -UseDeviceAuth`. That works with this tool,
but three things are worth knowing.

Device-code sessions expire less gracefully than interactive ones, and a stale session
is the most common cause of the HTTP 502 header error above. If a run fails partway,
sign in again before investigating anything else.

A device-code session is often issued to an operator whose access was granted at
workspace or resource-group scope rather than subscription scope. That is exactly the
condition that breaks `SelfHealing` above, so prefer the default literal mode in such
environments unless subscription-level read has been confirmed.

`-ValidateQueries` additionally needs a token for the Log Analytics data plane, a
different audience from ARM. Restricted tenants sometimes refuse to issue it. The run
degrades rather than failing: the validation section reports the error and the
workbooks are still scoped correctly.

### Workbook renders empty after scoping

**Cause:** The viewer does not have Log Analytics data-plane read access on the source
workspace. Updating a workbook is an ARM operation. Rendering the workbook is a Log
Analytics query operation. Those are separate permissions.

**Fix:** Assign **Log Analytics Reader** on both workspaces to every user who views the
workbook. The required action is
`Microsoft.OperationalInsights/workspaces/query/*/read`. Reopen the workbook after the
role assignment has propagated.

This is the first thing to check when the run succeeded but the dashboard is blank.

### Workbook shows only destination data, with no error

**Cause:** Self-healing mode only. The injected `{WBScopeSource}` parameter is an
Azure Resource Graph query. If the viewer cannot see the source workspace through
Resource Graph — no read access on it, or Resource Graph throttled — the parameter
resolves to empty, its reference drops out of the scope array, and the query runs
against the destination alone. That is exactly what is supposed to happen when the
workspace has been *deleted*, so there is no error to show.

The symptom is subtle: the workbook renders normally, it is simply missing the older
data. Compare a tile's row count against the same query run directly across both
workspaces.

**Fix:** Confirm the viewer has read access to the source workspace. Log Analytics
Reader grants `*/read`, which is sufficient for the workspace to appear in Resource
Graph. Run with `-ValidateQueries`, which resolves the parameter query as the running
identity and reports when it comes back empty.

If Resource Graph visibility cannot be granted, use `-ScopeMode Literal` instead. It
fails loudly rather than quietly, at the cost of having to revert before the source
workspace is decommissioned.

### Workbooks broke after the source workspace was deleted

**Cause:** They were scoped in `Literal` mode, which writes the source workspace
resource ID directly into each query. A deleted workspace cannot be resolved, so
Azure returns *resource not found* and the tile fails. Check the `scopeMode` field in
the workbook's `$dualScope` manifest, or the scope mode recorded in the run report.

**Fix:** Revert. This works even though the source workspace is already gone — revert
reads nothing from it.

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -Execute
```

Preflight reports the unreachable source as an expected warning in revert mode rather
than failing the run, so `-SkipPreflight` is not needed.

To avoid this next time, use the default `SelfHealing` mode, where the reference
disappears on its own when the workspace does.

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

