# Sentinel Workbook Scope Assistant — Customer Guide

## Overview

The Sentinel Workbook Scope Assistant is used after the Sentinel Migration Assistant
has copied workbooks from one Log Analytics workspace to another. The copied
workbooks live in the destination Sentinel blade, but their queries read only the
destination workspace. Historical data left in the source workspace is no longer
visible.

This tool re-scopes those workbooks so each eligible Log Analytics query reads from
both workspaces. It does that by setting workbook scope metadata, not by editing KQL.
When the source workspace is retired, `-Revert` restores destination-only scope.

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
| `-Revert` | Restore destination-only scope. Combine with `-Execute` to apply it. |
| `-Cloud <Commercial\|Gov>` | Azure cloud environment. Defaults to `Commercial` through config normalisation. |
| `-Force` | Skip the confirmation prompt in execute mode. Required for unattended runs. |
| `-ValidateQueries` | After scoping, run a real cross-workspace query and compare table coverage. Needs Log Analytics data-plane read access. |
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
| `Scope-Summary.html` | Self-contained dashboard with KPI cards, next steps, preflight warnings, validation findings, and workbook detail tables unless `-NoDetailTables` is used. |
| `scope-report.md` | Markdown report with the run header, workspace IDs, KPI summary, next steps, workbook results, ineligible query counts, preflight, validation, and collected errors. |
| `Scope-Results.xlsx` | Spreadsheet with Summary, Workbooks, Errors, and Validation sheets when validation ran. |
| `csv/` | CSV fallback folder, one file per sheet, when `ImportExcel` is unavailable or disabled. |
| `raw/RunResult.json` | Full structured run result for programmatic inspection. |
| `snapshots/` | Exact pre-edit `serializedData` for each processed workbook. This is the authoritative rollback source. |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed with no failures |
| `1` | Completed, but one or more items failed — check the report |
| `2` | Could not start: bad configuration, unreachable workspace, or missing permission |
