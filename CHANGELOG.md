# Sentinel Workbook Scope Assistant — Change Log

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses semantic versioning.

## [1.1.0] - 2026-08-31

### Added

- `-ScopeMode` with two values. `SelfHealing` references the source workspace
  through a hidden, global, deliberately not-required Azure Resource Graph resource
  picker injected into each workbook. Resource Graph only returns live resources, so
  once the source workspace is deleted the parameter resolves to empty, its
  reference drops out of `crossComponentResources`, and the query runs against the
  destination alone. `Literal` preserves the previous behaviour.
- Decommission readiness statement in the Markdown report and HTML summary, derived
  from the run rather than a fixed checklist: whether the workbooks will survive the
  source workspace being deleted, and what to do if they will not.
- `-ValidateQueries` now resolves the injected scope parameter as the running
  identity. Without Resource Graph visibility of the source workspace the parameter
  is empty and viewers silently see destination-only data, so this turns a quiet
  wrong answer into a reported finding.
- `.gitignore` now covers config-like files anywhere under `samples/`, not just at
  the repository root, while still tracking the sanitised `samples/config.yaml`.

### Changed

- **The default scope mode is now `SelfHealing`.** Workbooks scoped by earlier
  versions used literal resource IDs and stopped rendering the moment the source
  workspace was deleted; they had to be reverted first, and nothing enforced that
  ordering. Re-running against a workbook scoped by an earlier version migrates it.
- `-Revert` is optional in self-healing mode — tidy-up that removes the dead
  parameter — and remains mandatory before decommissioning in literal mode.
- In self-healing mode the customer's own workspace picker parameter is no longer
  rewritten, and `fallbackResourceIds` is left untouched. A literal in either place
  could not self-heal.

### Fixed

- `-Revert` no longer fails preflight when the source workspace has already been
  deleted. Reverting is what an operator does *because* the source is going away,
  and revert reads nothing from it, but preflight treated its absence as a blocking
  error and exited 2. The same run with `-SkipPreflight` succeeded, so preflight was
  refusing work that would have worked, and pushing operators onto a flag that also
  disables the destination checks. Source unreachability is now a warning when
  reverting and remains blocking when applying scope.

### Known limitations

- The self-healing behaviour has not been verified against live Azure. Every
  mechanism it relies on is individually documented, but the combination has only
  been exercised offline against saved workbook JSON. `-ScopeMode Literal` remains
  available as a fallback.

## [1.0.0] - 2026-08-26

### Added

- Initial release of the Sentinel Workbook Scope Assistant.
- Dual-scope transform for migrated Sentinel workbooks, using workbook
  `crossComponentResources` rather than rewriting KQL.
- Workspace picker parameter patching for parameter-driven workbook queries,
  including cross-subscription picker widening.
- `-Revert` mode with snapshot restore, embedded `$dualScope` manifest undo, and
  heuristic source-workspace stripping as a last resort.
- Dry-run reporting, HTML summary, Markdown report, Excel/CSV results export, raw JSON
  output, and per-workbook snapshots.
- Optional validation that probes cross-workspace query access and table coverage.
- Local pre-push Pester gate and a dormant GitHub Actions workflow for repositories
  where Actions is enabled.
