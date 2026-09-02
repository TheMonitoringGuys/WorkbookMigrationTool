# Recovery procedure

For an environment where the scope tool has been run and the migrated workbooks
still show no historical data.

This is written to be followed in order. It starts read-only, establishes which
of several indistinguishable causes is actually in play, and only then changes
anything. Skipping to the repair is how the wrong cause gets fixed twice.

> **Before anything else, stop running the tool against the affected
> environment.** A re-run can stamp workbooks as already scoped and make the
> assessment below harder to read.

---

## The symptom is ambiguous. That is the main difficulty.

"Workbooks open, tiles are empty, no historical data" is produced by at least
four different faults, and they look identical from the portal:

| # | Cause | What is actually wrong |
|---|---|---|
| A | **Viewer permissions** | Scope is correct. The viewer lacks Log Analytics Reader on the *source* workspace. A cross-workspace query silently returns only the workspaces the caller can read, so it reads as missing data rather than an error. |
| B | **Picker re-resolution** | Scope was written into a workspace picker, and the Workbooks engine re-resolves it at render time and drops the source — commonly because the picker's own Resource Graph query only enumerates one subscription. |
| C | **Scope present but overridden** | The workbook-level `fallbackResourceIds` names both workspaces, but individual queries carry their own scope and ignore it. |
| D | **Time range** | The window on screen postdates the last ingestion into the source workspace. |

Empty tiles rather than errors also tells you something useful: a **literal
reference to a deleted workspace produces an error, not silence.** If tiles are
empty and not erroring, the source workspace most likely still exists.

---

## Step 1 — Establish the facts, read-only

Nothing here writes.

```powershell
Connect-AzAccount
./tools/Test-WorkbookScope.ps1 -ConfigFile ./config.yaml
```

Record:

- Does the **source workspace still exist**, and when did it last receive data?
- Can **both workspaces be read in one query**?
- Per workbook: `OK`, `PARTIAL`, or `NOT SCOPED`.

The audit now prints the identity it ran as. That matters more than it looks:
every access check reflects *that* identity. An operator with Contributor or
Owner passes all of them while the people reporting empty tiles still cannot
read the source workspace.

## Step 2 — Separate permissions from scoping

Do this before changing any workbook. It takes two minutes and it decides
everything that follows.

**Have one affected viewer and one Owner open the same workbook, at the same
time range.**

| Result | Cause | Go to |
|---|---|---|
| Owner sees history, viewer does not | **A — permissions** | Step 3 |
| Neither sees history | **B or C — scoping** | Step 4 |
| Both see history | **D — time range**, or already fixed | Widen the time range and re-check |

Alternatively, re-run the audit from Step 1 signed in as an affected viewer.

## Step 3 — Repair permissions (cause A)

No workbook changes are needed, and none should be made.

Grant **Log Analytics Reader on both workspaces** to everyone who opens these
workbooks. The role provides
`Microsoft.OperationalInsights/workspaces/query/*/read`, which is what a
cross-resource query checks on every workspace it names.

Confirm with the affected viewer, not with an administrator account. Then stop —
the workbooks were never the problem.

## Step 4 — Repair scoping (causes B and C)

### 4a. Recover the run folders first

The `output/scope-*` folder from the run that applied the scope contains
`snapshots/`, which is the cleanest rollback source. Find it before changing
anything.

Note its limitation: **a snapshot holds the workbook content, not the whole ARM
resource.** It restores `serializedData`. It does not restore resource-level
fields such as tags. That is enough to undo a bad scope, and not enough to undo
everything a run touched.

### 4b. Revert to a known-good state

Preferred, when the run folder exists:

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -DryRun `
    -SnapshotPath ./output/scope-<source>-with-<dest>-<timestamp>
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -Execute `
    -SnapshotPath ./output/scope-<source>-with-<dest>-<timestamp>
```

Without a snapshot, revert falls back to the embedded `$dualScope` manifest, and
failing that to a heuristic. The report states which path was used. **Treat
`Heuristic` as requiring per-workbook review** — it cannot know whether a scope
array it found was created by this tool or was already there.

### 4c. Re-apply, and force it

A workbook carrying a `$dualScope` manifest can be reported as already scoped.
If the manifest is present but the scope is not, use `-ForceRescope`:

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -DryRun
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute -ForceRescope
```

If the audit named workbooks with **no migration tag**, they were skipped by
design. Include them deliberately:

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Execute -IncludeAllWorkbooks
```

Be aware that a Content Hub solution update can revert scoping on its own
workbooks, so solution-managed workbooks may need this again after an update.

### 4d. Verify by data, as a viewer

This is the step that has historically been skipped, and skipping it is why the
tool was repeatedly reported as working.

- Re-run `./tools/Test-WorkbookScope.ps1 -ConfigFile ./config.yaml`.
- Then **open a sample of workbooks as a normal viewer** — not as an Owner — and
  confirm historical rows actually render.

A clean report is not evidence. The report describes what the tool wrote. What
matters is what the Workbooks engine renders for the person complaining.

## Step 5 — Confirm the decommissioning contract

Check `scopeMode` in any workbook's `$dualScope` manifest, or the run report.

- **`Literal`** — the default. Both workspace IDs are written directly.
  **`-Revert` is mandatory before the source workspace is deleted.** A literal
  reference to a deleted workspace makes the tile fail.
- **`SelfHealing`** — opt-in only. The reference drops out on its own, but every
  viewer needs Reader on the source *subscription*, not just the workspace.

Earlier versions of `docs/runbook.md` named self-healing as the default and said
there was no ordering constraint. That was wrong, and following it against a
`Literal` run would break every scoped tile at decommissioning. If the source
workspace has already been deleted and tiles now show *errors* rather than being
empty, revert still fixes them — it reads nothing from the source:

```powershell
./Sentinel-Workbook-Scope-Assistant.ps1 -ConfigFile ./config.yaml -Revert -Execute
```

## Step 6 — Hand back

Record, per workbook: the scope mechanism used, how it was verified, and who
confirmed it rendered. "The report was clean" is not an entry.

---

## What is still not verified

Being explicit, because over-claiming here is what caused the original problem.

- The offline test suite runs entirely against JSON the tool produced itself,
  with the network stubbed. It cannot observe how the Workbooks engine renders a
  scoped workbook.
- `tests/Live.Azure.Tests.ps1` is the suite that can prove the tool works: it
  runs against a real lab, reads the workbooks back from ARM, and requires query
  results from **both** workspaces. It skips unless a lab is configured.
- Until that suite has been run green against a lab, the correct statement about
  this tool is that its logic is tested and its behaviour against Azure is not.
