# Sentinel Workbook Scope Assistant

Re-scopes Microsoft Sentinel workbooks after a workspace migration. After the
Sentinel Migration Assistant copies workbooks from one Log Analytics workspace to
another, those workbooks read only the destination workspace. Historical data left
in the source workspace becomes invisible.

This tool updates the migrated workbooks so their Log Analytics queries read from
both workspaces. The workbook still lives in the destination Sentinel blade.

By default the source is referenced in a way that **survives the old workspace being
deleted**: when you eventually turn the old Sentinel off, the workbooks keep
rendering against the destination alone. Nothing has to be reverted first. See
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
| `SelfHealing` (default) | Destination as a literal, plus `{WBScopeSource}` — a hidden parameter backed by Azure Resource Graph | Resource Graph stops returning the workspace, the parameter resolves to empty, the reference drops out, and the query runs against the destination alone. **The workbook keeps working.** |
| `Literal` | Both workspace resource IDs written directly | Azure returns *resource not found* and the tile fails. **The workbooks must be reverted before the workspace is deleted.** |

Self-healing works because the injected parameter is a Resource Graph resource
picker filtered to exactly one workspace. Resource Graph is an inventory of live
resources, so a deleted workspace simply stops appearing in the result. The
parameter is marked global so every query can resolve it, hidden so viewers never
see it, and deliberately **not** required — a required picker with no results would
block every query that depends on it, turning the graceful degradation into a hard
stop.

`Literal` is kept as an escape hatch. Use it if self-healing misbehaves in your
tenant.

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
