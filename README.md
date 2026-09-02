# Sentinel Workbook Scope Assistant

Re-scopes Microsoft Sentinel workbooks after a workspace migration. After the
Sentinel Migration Assistant copies workbooks from one Log Analytics workspace to
another, those workbooks read only the destination workspace. Historical data left
in the source workspace becomes invisible.

This tool updates the migrated workbooks so their Log Analytics queries read from
both workspaces. The workbook still lives in the destination Sentinel blade.

By default the source is referenced by its resource ID, so the workbooks must be
reverted before the old workspace is decommissioned. An opt-in `-ScopeMode
SelfHealing` removes that ordering requirement, at the cost of requiring every
viewer to have Reader on the source subscription. See
[How scoping works](#how-scoping-works).

## Requirements

- PowerShell 7+
- The `Az.Accounts` module
- `powershell-yaml` (for YAML config files — installed automatically if missing)
- `ImportExcel` (optional — installed automatically when writing the workbook;
  without it, results are written as CSV instead of XLSX)
- **Microsoft Sentinel Contributor** or equivalent write access on the destination
  resource group
- Read access on the source workspace
- **Log Analytics Reader on both workspaces for everyone who views the workbooks**

The viewer permission is separate from the identity running the tool. The update can
succeed, the report can be clean, and the workbook can still render empty for a user
who does not have `Microsoft.OperationalInsights/workspaces/query/*/read` on the
source workspace.

The tool checks startup prerequisites and workspace reachability before it writes.
`Az.Accounts` is never installed for you, because organisations usually pin a
specific version. Pass `-NoAutoInstall` to turn automatic installs off; YAML config
then stops with instructions, and the results workbook falls back to CSV.

## Quick start

```powershell
Connect-AzAccount

# 1. Describe the pair of workspaces
Copy-Item ./samples/config.yaml ./config.yaml    # then edit it

# 2. See what would change - writes nothing
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -DryRun

# 3. Apply dual scope - asks before writing
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute

# 4. Validate data-plane access and table coverage
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute -ValidateQueries

# Confirm the result, and diagnose it if the old workspace's data is missing
./tools/Test-WorkbookScope.ps1 -ConfigFile ./config.yaml

# If a run reports workbooks as already scoped but they are not, redo them all
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -ForceRescope -Execute

# 5. Later, when the source workspace is decommissioned - optional tidy-up
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -Execute
```

Step 5 is not a prerequisite for turning the old workspace off. In the default
self-healing mode the workbooks survive the deletion on their own; reverting just
removes the now-dead scope parameter. In `-ScopeMode Literal` it *is* mandatory, and
must be run before the source workspace is deleted.

The sample config is commented, so it doubles as the reference for every option.
JSON is accepted too, using the same key names, and needs no extra module at all.
See [troubleshooting](docs/troubleshooting.md) for a JSON example.

Each run writes a timestamped folder under `./output/`. Open `Scope-Summary.html`
from it first; `scope-report.md` and `Scope-Results.xlsx` carry the same results in
Markdown and spreadsheet form.

No config file? Pass the workspace values directly:

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -DryRun `
    -SourceSubscriptionId <id> -SourceResourceGroup <rg> -SourceWorkspace <ws> `
    -DestinationSubscriptionId <id> -DestinationResourceGroup <rg> -DestinationWorkspace <ws>
```

## How scoping works

Each query item in a workbook's JSON may carry a `crossComponentResources` array
naming the resources it reads. The Workbooks engine unions across those resources.
This tool sets that array. **No KQL is ever rewritten.** `properties.sourceId` is
never modified, so the workbook stays attached to the destination Sentinel workspace.

### Scope modes

| Mode | How the source is referenced | When the source workspace is deleted |
|---|---|---|
| `Literal` (default) | Both workspace resource IDs written directly | Azure returns *resource not found* and the tile fails. **The workbooks must be reverted before the workspace is deleted.** |
| `SelfHealing` | Destination as a literal, plus `{WBScopeSource}` — a hidden parameter backed by Azure Resource Graph | Resource Graph stops returning the workspace, the parameter resolves to empty, the reference drops out, and the query runs against the destination alone. **The workbook keeps working.** |

Self-healing removes the need to revert before decommissioning, but it is **opt-in**,
not the default. Its Resource Graph query runs in the *viewer's* security context,
scoped to the source subscription. A viewer without read access at that scope gets
HTTP 502 complaining about the authorization header — and because the parameter is
global, that takes the whole workbook down rather than one tile. Log Analytics Reader
granted at workspace scope is **not** sufficient for this.

It shipped as the default in 1.1.0 and was reverted in 1.2.0 after a customer hit
exactly that. The mode's assumption — that the parameter resolves empty when it cannot
see the workspace — holds when the workspace has been *deleted*, but not when the
caller lacks *permission*: Resource Graph returns an error, not an empty set.

Before choosing it, grant every viewer Reader on the source subscription and confirm
with `-ValidateQueries`, which resolves the parameter query as the running identity.

### What each query shape gets

| Shape | Handling |
|---|---|
| Query with no explicit scope | Destination literal plus the parameter reference. |
| Literal `value::selected` or `value::all` | Real resources preserved, then destination plus the parameter reference. |
| Parameter reference such as `{Workspace}` | The customer's own picker is left alone; the parameter reference is appended beside it. |

Dropdown parameters that are themselves Log Analytics queries — `User`, `Category`,
`Apps` and similar — are scoped too. Without that, the dropdown would not list values
that exist only in the old workspace.

In self-healing mode `fallbackResourceIds` is deliberately left untouched: a literal
there could not self-heal, which would reintroduce the exact failure the mode exists
to remove.

A measured 16-workbook migration held 533 Log Analytics queries: 290 had no explicit
scope, 243 were parameter-driven, and none hardcoded a workspace ID or used the
`workspace()` KQL function. All 523 eligible queries were verified offline to keep a
usable destination scope after simulating deletion of the source workspace.

## Diagnostics

Two read-only scripts, for when a run reports success and the dashboards disagree.
Both accept the same config file the tool uses, so nothing has to be retyped.

```powershell
# Is each workbook actually reading both workspaces, and can the old one be read at all?
./tools/Test-WorkbookScope.ps1 -ConfigFile ./config.yaml

# Can this machine authenticate to Azure and list workbooks?
./tools/Test-ScopeConnection.ps1 -SubscriptionId <sub> -ResourceGroupName <rg> -WorkspaceName <ws>
```

`Test-WorkbookScope.ps1` checks both workspaces before it looks at any workbook -
whether each resolves in ARM, when it last received data, and whether both can be read
in one query. Scope written perfectly into a workbook still shows nothing if the source
workspace does not exist at the ID the run was given, cannot be read by the viewer, or
holds no data in the period on screen. None of that is visible in the workbook itself,
and all of it looks the same from the outside.

It then reports each workbook as `OK`, `PARTIAL` or `NOT SCOPED`, resolving every query
by the route it actually uses rather than assuming they all work the same way.

Neither script writes anything, and neither prints any token material.

## What it will not do

- It does not rewrite KQL.
- It does not move, copy, or delete workbooks.
- It does not change `properties.sourceId`.
- It does not scope Azure Resource Graph queries (`queryType 1`), Application
  Insights queries, or Azure Monitor metrics. Pointing those at a Log Analytics
  workspace would break them.
- It does not grant viewer permissions. Assign Log Analytics Reader on both
  workspaces separately.

Microsoft documents a limit of up to 100 workspaces in a single cross-resource query,
so a two-workspace scope is well inside the limit. For rate limiting, one
cross-resource query counts as one API query.

## Safety

- Dry run is the default posture; nothing is written without `-Execute`.
- `-Execute` shows the destination workspace and the planned changes, then waits for
  confirmation. `-Force` skips the prompt for unattended runs.
- The source workspace is never modified or deleted.
- Each workbook is snapshotted before the first edit into the run folder's
  `snapshots/` directory.
- Revert uses three tiers, in order: snapshot restore, embedded `$dualScope` manifest,
  then a heuristic that strips the source reference. The report states which path
  was used.
- Revert works even after the source workspace has been deleted. It reads nothing
  from the source, so preflight treats an unreachable source as expected when
  reverting rather than refusing the run.

If a user edits and re-saves a workbook in the Azure portal, the portal's
re-serialization may drop the embedded manifest or the injected parameter. The
snapshot in the run folder remains the authoritative rollback source.

With `-IncludeAllWorkbooks`, workbooks installed by a Content Hub solution can have
this scoping silently reverted by a later solution update.

## Known limitations

**Nothing in this tool has been verified end to end against live Azure.** The
offline test suite runs with the network stubbed and asserts on JSON the tool
produced itself. It cannot observe how the Workbooks engine renders a scoped
workbook, which is what actually decides whether the tool works. A green offline
run is not verification, and reporting it as such is how this tool was signed off
while returning no historical data in a customer tenant.

`tests/Live.Azure.Tests.ps1` is the suite that can settle it: it runs the real
tool against a real lab, reads the workbooks back out of ARM, and requires query
results from **both** workspaces. It skips unless the lab variables are set. Run
it before describing this tool as verified. See [Recovery](docs/recovery.md) if an
environment is already affected.

**The self-healing behaviour has not been verified against live Azure.** Each
mechanism it relies on is individually documented by Microsoft — `isGlobal`,
`isHiddenWhenLocked`, an unset `isRequired`, and an empty parameter collapsing out of
a resource array that also holds a literal — but the combination has only been
exercised offline against saved workbook JSON. Validate in a lab before production
use; `-ScopeMode Literal` is the fallback if it does not behave as documented.

**Self-healing can degrade silently.** If a viewer cannot see the source workspace
through Resource Graph — missing permission, or Resource Graph throttled — the
parameter resolves to empty and they get destination-only data with no error at all.
That is a wrong answer delivered quietly, where the literal mode would have failed
loudly. Log Analytics Reader grants `*/read`, so anyone who can query the source
workspace should also see it in Resource Graph, but confirm it with
`-ValidateQueries`, which checks exactly this.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed with no failures |
| `1` | Completed, but some items failed — check the report |
| `2` | Could not start: bad config, unreachable workspace, or missing permission |

## Documentation

| Document | Use it for |
|---|---|
| [Customer Guide](docs/customer-guide.md) | Setup, every parameter, expected behaviour, output files |
| [Runbook](docs/runbook.md) | The step-by-step procedure, re-runs, rollback, CI/CD |
| [Recovery](docs/recovery.md) | Workbooks show no historical data after a run — diagnosis and repair |
| [Troubleshooting](docs/troubleshooting.md) | When something fails |
| [Changelog](CHANGELOG.md) | What changed, including breaking changes |

Full parameter help is in the script itself:

```powershell
Get-Help ./Sentinel-Workbook-Scope-Assistant.ps1 -Full
```

## Development

Run the test suite:

```powershell
Invoke-Pester -Path ./tests
```

### Test gate

This repository has no remote configured yet. When it lands alongside the Sentinel
Migration Assistant under the same Enterprise Managed User account, expect GitHub
Actions not to run: Actions is disabled there by enterprise policy, and the API
reports zero registered workflows and zero runs. `.github/workflows/tests.yml` is
present and valid, and will start working unchanged in an organisation with Actions
enabled.

Because nothing server-side is guaranteed to check the tests, the gate is local.
Install it once per clone:

```powershell
./tools/Install-GitHooks.ps1
```

That points `core.hooksPath` at `tools/hooks`, enabling a `pre-push` hook that runs the
full suite and refuses the push if anything fails. The path is relative, so a single
setting works correctly in the main clone and in every worktree.

To bypass for one push — a docs-only fixup, or a deliberate work-in-progress:

```powershell
git push --no-verify
```

To remove the gate entirely:

```powershell
./tools/Install-GitHooks.ps1 -Uninstall
```
