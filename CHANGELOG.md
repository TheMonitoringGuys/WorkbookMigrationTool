# Sentinel Workbook Scope Assistant — Change Log

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses semantic versioning.

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
