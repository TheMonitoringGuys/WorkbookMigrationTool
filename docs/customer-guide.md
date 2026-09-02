# Sentinel Workbook Scope Assistant — Customer Guide

## Overview

The Sentinel Workbook Scope Assistant is used after the Sentinel Migration Assistant
has copied workbooks from one Log Analytics workspace to another. The copied
workbooks live in the destination Sentinel blade, but their queries read only the
destination workspace. Historical data left in the source workspace is no longer
visible.

This tool re-scopes those workbooks so each eligible Log Analytics query reads from
both workspaces. It does that by setting workbook scope metadata, not by editing KQL.

By default (`-ScopeMode Literal`) the source workspace is referenced by its resource
ID, written directly into each query's scope. **`-Revert` is therefore mandatory
before the source workspace is decommissioned** — a literal reference to a deleted
workspace makes the tile fail.

The opt-in `-ScopeMode SelfHealing` removes that ordering requirement by referencing
the source through a hidden parameter that resolves only while the workspace exists,
at the cost of requiring every viewer to have Reader on the source subscription. See
[Scope modes](#scope-modes).

## Prerequisites

### Software

| Requirement | Minimum version |
|---|---|
| PowerShell | 7.0+ |
| Az.Accounts module | Installed and available |
| powershell-yaml module | Only for YAML config files. Installed automatically if missing. |
| ImportExcel module | Optional. Installed automatically when writing the workbook; results fall back to CSV without it. |

The tool verifies startup prerequisites and reports what is missing. `Az.Accounts` is
not installed automatically. `powershell-yaml` and `ImportExcel` are installed to
`CurrentUser` only when needed. `-NoAutoInstall` disables both automatic installs.

### Azure access for the operator

| Scope | Permission | Purpose |
|---|---|---|
| Source workspace or resource group | Reader, or equivalent read access | Resolve the source workspace and build its resource ID. |
| Destination resource group | Microsoft Sentinel Contributor, or equivalent workbook write access | Read and update the migrated workbook resources. |

The destination write check is deliberately conservative. The tool does not create and
delete a workbook just to prove access, so the write probe may be reported as
unknown. A missing write grant then appears when the first PUT is attempted.

### Azure access for workbook viewers

Everyone who views the re-scoped workbooks needs
`Microsoft.OperationalInsights/workspaces/query/*/read` on **both** workspaces. The
built-in **Log Analytics Reader** role provides it.

This is the most common failure mode. The operator can run the tool successfully with
Contributor access, while a viewer without Log Analytics Reader on the source sees an
empty workbook. Assign the viewer role before treating the run as complete.

### Authentication

```powershell
Connect-AzAccount
# For Gov cloud:
Connect-AzAccount -Environment AzureUSGovernment
```

Service principals work too, provided the same roles are assigned.

## Configuration

Copy `samples/config.yaml` and fill in the workspace details:

```yaml
source:
  subscriptionId: "aaaa-bbbb-cccc-dddd"
  resourceGroupName: "rg-sentinel-old"
  workspaceName: "law-sentinel-old"

destination:
  subscriptionId: "eeee-ffff-0000-1111"
  resourceGroupName: "rg-sentinel-new"
  workspaceName: "law-sentinel-new"

options:
  dryRun: true
  cloud: "Commercial"
  validateQueries: false
```

A config file written for the Sentinel Migration Assistant can be reused. Its `target`
section is read as this tool's `destination` section.

YAML needs `powershell-yaml`. JSON uses the same key names and needs no extra module;
see [troubleshooting](troubleshooting.md#json-config-example) for a complete example.

## Quick start

```powershell
# Preview
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -DryRun

# Apply
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute

# Apply and validate data-plane access
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute -ValidateQueries

# Revert before source decommissioning
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -Execute
```

`-Execute` prompts before writing unless `-Force` is passed. In unattended automation,
use `-Force`; otherwise the run stops rather than guessing.

## Scope modes

`-ScopeMode` controls how the source workspace is referenced, and therefore what
happens when that workspace is eventually deleted.

### SelfHealing (opt-in)

Each eligible query is scoped to the destination workspace as a literal, plus a
reference to `{WBScopeSource}` — a parameter the tool injects into the workbook. That
parameter is an Azure Resource Graph resource picker filtered to the single source
workspace ID.

Resource Graph is an inventory of live resources. Once the source workspace is
deleted it stops being returned, the parameter resolves to empty, the reference drops
out of the scope array, and the query runs against the destination alone. The
workbook keeps rendering.

The injected parameter is marked global so queries nested inside groups can resolve
it, hidden so viewers never see it, and deliberately not required. A required picker
with no results blocks every query that depends on it, which would turn the graceful
degradation into a hard failure.

The customer's own workspace picker is not modified in this mode; the reference is
appended beside it. `fallbackResourceIds` is left untouched, because a literal there
could not self-heal.

### Literal (default)

Both workspace resource IDs are written directly into each query's scope array.
Easier to read in the raw JSON, and it depends on nothing but the two workspaces —
no Resource Graph, no subscription-scope permission. The cost is that the workbooks
stop rendering the moment the source workspace is deleted, so they must be reverted
before it is decommissioned.

### Choosing

| | Literal (default) | SelfHealing |
|---|---|---|
| Survives source deletion | No | Yes |
| Revert required before decommissioning | Yes | No |
| Depends on Resource Graph | No | Yes |
| Viewer permission needed | Log Analytics Reader on both workspaces | The same, **plus Reader on the source subscription** |
| Failure mode when a viewer lacks that access | Tile shows a clear error | **HTTP 502 on the whole workbook** |
| Exercised against a live tenant | **No — see README "Known limitations"** | **No** |

Prefer `Literal` unless you have confirmed subscription-scope read for every person
who will open these workbooks. Self-healing's advantage is real — it removes the
requirement to revert before decommissioning — but it trades a narrow, obvious
failure for a broad, confusing one when permissions are short.

The self-healing transform itself is verified offline against 523 real queries: all
of them keep a usable destination scope when the source workspace disappears. That is
an offline result only — it proves the JSON transform, not the runtime behaviour of
the Workbooks engine. Neither mode has been verified end to end against a live tenant.
The permission caveat above is derived from Azure's documented behaviour and a
customer incident, not from a controlled live test.

## CLI parameters

All config keys can be overridden by CLI parameters. CLI values win.

| Parameter | Description |
|---|---|
| `-ConfigFile <path>` | YAML or JSON configuration file. A migration assistant config is accepted; `target` is treated as `destination`. |
| `-SourceSubscriptionId <id>` | Subscription of the workspace migrated away from. |
| `-SourceResourceGroup <name>` | Resource group of the source workspace. |
| `-SourceWorkspace <name>` | Source workspace name; this holds the older data. |
| `-DestinationSubscriptionId <id>` | Subscription of the workspace migrated to. |
| `-DestinationResourceGroup <name>` | Resource group of the destination workspace. |
| `-DestinationWorkspace <name>` | Destination workspace name, where the workbooks live now. |
| `-DryRun` | Report what would change and write nothing. This is the default parameter set. |
| `-Execute` | Apply the changes. Prompts unless `-Force` is also passed. |
| `-Revert` | Restore destination-only scope. Combine with `-Execute` to apply it. Optional in `SelfHealing` mode, mandatory before decommissioning in `Literal` mode. Works even after the source workspace has been deleted. |
| `-ScopeMode <SelfHealing\|Literal>` | How the source workspace is referenced. Defaults to `Literal`. See [Scope modes](#scope-modes). |
| `-Cloud <Commercial\|Gov>` | Azure cloud environment. Defaults to `Commercial` through config normalisation. |
| `-Force` | Skip the confirmation prompt in execute mode. Required for unattended runs. |
| `-ValidateQueries` | After scoping, run a real cross-workspace query and compare table coverage. In `SelfHealing` mode it also confirms the injected scope parameter resolves for the running identity. Needs Log Analytics data-plane read access. |
| `-LookbackDays <n>` | Lookback window for validation table inventory. Valid range is 1 to 365; default is 7. |
| `-WorkbookFilter <pattern>` | Wildcard match against workbook display names, for example `Azure*`. Empty means all matched workbooks. |
| `-IncludeAllWorkbooks` | Act on every Sentinel workbook in the destination resource group, not only workbooks tagged as migrated. |
| `-SnapshotPath <path>` | Previous run directory whose `snapshots/` files should be used by `-Revert`. |
| `-RetryCount <n>` | Retries on throttled or transient API errors. Valid range is 0 to 10; default is 3. |
| `-ThrottleMs <n>` | Delay between API calls in milliseconds. Valid range is 0 to 60000; default is 100. |
| `-SkipPreflight` | Skip workspace reachability and permission checks. Not recommended. |
| `-NoDetailTables` | Build a slim HTML summary without embedded per-workbook tables. |
| `-NoAutoInstall` | Do not install missing PowerShell modules. YAML then stops if `powershell-yaml` is missing, and results export uses CSV if `ImportExcel` is missing. |
| `-OutputDir <path>` | Parent directory for run folders. Defaults to `./output`. |

Every parameter is also documented in the script's own help:

```powershell
Get-Help ./Sentinel-Workbook-Scope-Assistant.ps1 -Full
```

## Expected behaviour

The tool discovers workbooks in the destination resource group. By default it only
considers workbooks tagged `MigratedFromWorkbookId`, which are the ones created by the
Sentinel Migration Assistant. `-IncludeAllWorkbooks` widens the search to every
Sentinel workbook in that resource group.

For each workbook, it parses `properties.serializedData`, finds eligible Log Analytics
queries, and applies the dual-scope transform. Query types that do not use Log
Analytics workspace scope are skipped. Azure Resource Graph queries (`queryType 1`),
Application Insights, and Azure Monitor metrics are intentionally left alone.

No KQL is rewritten. The workbook's `properties.sourceId` is not changed. The tool
sets `crossComponentResources` on query items or updates workspace picker parameters
when the query points at a parameter such as `{Workspace}`.

For cross-subscription workspaces, workspace picker parameters usually query Azure
Resource Graph scoped to `{Subscription}`. The source workspace would not appear in
that picker, so the tool widens the picker scope automatically and preflight warns.

For cross-region workspaces, cross-resource queries have to serialise and move
intermediate data between regions. Dashboards can be measurably slower. Preflight
warns but does not block.

## Output files

Each run writes its own timestamped folder beneath `output/`:

```text
output/scope-<source-ws>-with-<destination-ws>-<yyyyMMdd-HHmmss>/
├── Scope-Summary.html
├── Scope-Results.xlsx        # or csv/ when XLSX cannot be written
├── scope-report.md
├── raw/
│   └── RunResult.json
└── snapshots/
    └── <workbook-id>.json
```

| Artifact | Description |
|---|---|
| `Scope-Summary.html` | Self-contained dashboard with KPI cards, the scope mode, a decommission readiness statement, next steps, preflight warnings, validation findings, and workbook detail tables unless `-NoDetailTables` is used. |
| `scope-report.md` | Markdown report with the run header, scope mode, workspace IDs, KPI summary, decommission readiness, next steps, workbook results, ineligible query counts, preflight, validation, and collected errors. |
| `Scope-Results.xlsx` | Spreadsheet with Summary, Workbooks, Errors, and Validation sheets when validation ran. |
| `csv/` | CSV fallback folder, one file per sheet, when `ImportExcel` is unavailable or disabled. |
| `raw/RunResult.json` | Full structured run result for programmatic inspection. |
| `snapshots/` | Exact pre-edit `serializedData` for each processed workbook. This is the authoritative rollback source. |

### Reading the KPI summary

Two measures look similar and mean different things. Both are rendered only when
their count is greater than zero, so a run never shows one that does not apply.

| Measure | Meaning |
|---|---|
| Parameters patched | A workspace picker the tool actually rewrote to name both workspaces. Literal mode only. |
| Scoped via existing picker | A query that kept its own picker untouched and had the self-healing scope reference appended beside it. Self-healing mode only. |
| Scoped on weak evidence | Workbooks reporting success where the scope did **not** reach any query directly. Shown only when it applies. |

The distinction matters because self-healing deliberately leaves the customer's
picker alone. An earlier version counted both as "parameters patched", so a run
reported having patched 237 parameters while every picker was byte-identical.

### Scope evidence

`Scoped` covers routes of very different strength, and reporting them
identically is how a run can look completely clean while a workbook returns no
historical data. Each scoped workbook now carries an evidence label:

| Evidence | Meaning |
|---|---|
| `Per-query` | Queries name the source workspace directly. Strongest. |
| `Picker` | A workspace picker carries the source. Real, but depends on the picker resolving at render time for the viewer. |
| `Fallback only` | **Only** the workbook-level `fallbackResourceIds` was extended. Any query carrying its own scope ignores it. |
| `None` | Nothing changed, yet the action claims otherwise. |

Anything other than `Per-query` or `Picker` is listed by name under *Workbooks
scoped on weak evidence* in the report. Check those first when historical data
is missing.

### Decommission readiness

The report and the HTML summary both state, in one sentence derived from the run,
whether the workbooks will keep working once the source workspace is deleted:

- Self-healing, workbooks scoped, nothing failed - they will keep working, and no
  revert is required first.
- Literal - they will stop rendering, and must be reverted before the source
  workspace is removed. The revert command is given.
- Anything failed - readiness is unknown for those workbooks, and they are named.
- A revert run - the workbooks are back to destination-only and the source can go.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed with no failures |
| `1` | Completed, but one or more items failed — check the report |
| `2` | Could not start: bad configuration, unreachable workspace, or missing permission |

