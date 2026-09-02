# Sentinel Workbook Scope Runbook

## Pre-run checklist

1. [ ] Confirm the Sentinel Migration Assistant has already copied the workbooks to the destination workspace.
2. [ ] Confirm the source workspace still exists and holds the historical data users need.
3. [ ] Confirm the operator has destination write access and source read access.
4. [ ] Assign Log Analytics Reader on both workspaces to the users who view these workbooks.
5. [ ] Authenticate with `Connect-AzAccount`.
6. [ ] Create a config file from `samples/config.yaml`, or reuse the migration assistant config.
7. [ ] Run a dry run and review the output before executing.

The tool checks its own prerequisites at startup. You do not need to verify module
versions by hand unless your environment blocks module installation.

## Step-by-step procedure

### Step 1: Dry run

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -DryRun
```

Review the run folder under `output/`:

- Open `Scope-Summary.html` first.
- Confirm the source and destination workspace names and resource IDs.
- Check the number of discovered workbooks.
- Check the eligible and ineligible query counts.
- Read the preflight warnings. Cross-subscription and cross-region warnings are not
  failures, but they change what users should expect.
- Confirm that no unexpected workbook names are in scope.

If no workbooks are listed, the default filter probably found no workbooks tagged
`MigratedFromWorkbookId`. Either check that the workbooks were created by the
migration assistant, adjust `-WorkbookFilter`, or deliberately use
`-IncludeAllWorkbooks`.

### Step 2: Review permissions before execute

The tool changes workbook definitions through ARM, so the operator needs write access
on the destination resource group. That is not enough for the dashboard to work for
end users.

Every viewer needs Log Analytics Reader on both workspaces. Without that role on the
source, the workbook update succeeds and the workbook then renders empty for that
viewer. Fix this before rollout, not after the support call.

### Step 3: Execute dual scope

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute
```

Before writing, the tool prints the destination workspace and affected workbook count
and asks for confirmation. Check the destination name at that point. It is the last
safe stop before ARM updates are sent.

For unattended execution:

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute -Force
```

### Step 4: Validate

For the first run against a workspace pair, run validation:

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute -ValidateQueries
```

Validation runs one real cross-workspace query and compares which tables hold data in
each workspace over the configured lookback window. It is diagnostic only; a
validation failure does not undo workbook updates. It needs Log Analytics data-plane
read access, which is separate from the ARM permissions used to update workbooks.

In the portal, open a sample of scoped workbooks from the destination Sentinel blade.
Confirm that the workbook opens there, not under the source workspace, and that charts
show the expected historical range.

### Step 5: Record the run folder

Keep the run folder path with the change record. The `snapshots/` directory is the
exact restore source for revert. The embedded manifest is useful, but the portal can
re-serialize workbook JSON and drop it if someone edits and saves the workbook later.

## Re-running

Re-running is safe. A workbook that already carries a matching `$dualScope` manifest
is reported as already scoped and is not written again. A failed workbook can be
retried by running the same command again.

Use `-WorkbookFilter` to narrow a corrective run:

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute `
    -WorkbookFilter "Azure*"
```

Use `-IncludeAllWorkbooks` only when you intend to include workbooks that were not
created by the migration assistant. Content Hub solution updates can silently revert
scoping on solution-managed workbooks.

## Rollback during rollout

The preferred rollback is `-Revert` with `-SnapshotPath` pointing at the run that
applied the scope:

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -Execute `
    -SnapshotPath ./output/scope-old-with-new-20260826-120000
```

This restores the exact `serializedData` captured before the edit. It is the cleanest
path because it does not need to infer what changed.

If no snapshot path is supplied, revert uses the embedded `$dualScope` manifest in the
workbook. That performs a surgical undo of every recorded change.

If neither snapshot nor manifest is available, revert falls back to a heuristic: it
strips the source workspace ID and the injected scope parameter from the workbook. The
result is usually correct, but it cannot know whether a scope array was created by this
tool or already existed. The report states when this fallback was used.

## Decommissioning

What you do here depends on the scope mode the workbooks were written in. The report
from the scoping run states it, and so does the `scopeMode` field in each workbook's
`$dualScope` manifest.

### Self-healing mode (opt-in: `-ScopeMode SelfHealing`)

This applies **only** if the run was made with `-ScopeMode SelfHealing`. It is not the
default. If you did not pass that flag, read [Literal mode](#literal-mode-the-default)
below instead — deleting the source workspace without reverting will break every
scoped tile.

There is no ordering constraint. The workbooks reference the source workspace through
a parameter backed by Azure Resource Graph, which stops returning the workspace once
it is deleted. The reference drops out and the queries run against the destination
alone.

Turn the source workspace off whenever you are ready. Afterwards, if you want to tidy
up the now-dead parameter and the scope manifest:

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -DryRun
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -Execute
```

This works before or after the source workspace is deleted. Revert reads nothing from
the source, so preflight reports an unreachable source as an expected warning rather
than failing the run.

Before relying on this the first time, confirm the behaviour in a lab. Delete a
disposable source workspace and open a scoped workbook. The self-healing path is
built on documented Azure behaviour but has not been verified end to end against a
live tenant.

### Literal mode (the default)

This is what you get unless you explicitly passed `-ScopeMode SelfHealing`.

Reverting **is** mandatory, and it must happen before the source workspace is
deleted. A workbook still holding a literal reference to a deleted workspace returns
*resource not found* and the tile fails.

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -DryRun
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -Execute
```

Review the report and confirm the method. Prefer `Snapshot` if the original run folder
is available. `Manifest` is acceptable. `Heuristic` means the authoritative evidence
was missing, so sample the resulting workbooks before the source workspace is removed.

If the source workspace has already been deleted and the workbooks are broken, the
same revert command still fixes them. That path used to be blocked by preflight; it
is not any more.

After revert, open the destination workbooks and confirm they still render using only
destination data.

## CI/CD

For scheduled or pipeline use, pass `-Execute -Force`. Without `-Force`, execute mode
prompts for confirmation and a non-interactive run stops by design.

```yaml
# Azure DevOps example
- task: AzurePowerShell@5
  inputs:
    azureSubscription: 'service-connection'
    scriptType: 'FilePath'
    scriptPath: './Sentinel-Workbook-Scope-Assistant.ps1'
    scriptArguments: '-ConfigFile ./config.json -Execute -Force'
    azurePowerShellVersion: 'LatestVersion'
    pwsh: true
```

JSON config is often simpler in pipelines because it needs no `powershell-yaml` module
and avoids a PowerShell Gallery call. If your agents block module installation, use
JSON or pre-install the module and pass `-NoAutoInstall`.

The tool sets an exit code the pipeline can act on:

| Exit code | Meaning |
|---|---|
| `0` | Completed with no failures |
| `1` | Completed, but one or more items failed — check the report |
| `2` | Could not start: bad config, unreachable workspace, or missing permission |

## Local development gate

Run the offline test suite before pushing:

```powershell
Invoke-Pester -Path ./tests
```

Install the local pre-push gate once per clone:

```powershell
./tools/Install-GitHooks.ps1
```

The hook runs the full Pester suite and refuses the push on failure. GitHub Actions is
present as a valid workflow file, but it does not execute in this repository while
enterprise policy disables Actions for the private EMU repo.
