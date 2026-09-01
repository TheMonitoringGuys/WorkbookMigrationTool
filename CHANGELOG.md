# Sentinel Workbook Scope Assistant — Change Log

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses semantic versioning.

## [1.2.6] - 2026-09-01

### Fixed

- **A partial run no longer reports success.** When the per-workbook fallback could not
  read a workbook, it warned and dropped it. The orchestrator never learned, so a run that
  processed eleven of sixteen workbooks printed `Failed: 0`, wrote a report describing an
  eleven-workbook run, and exited 0 - while five workbooks quietly went on showing
  destination data only.

  That is the same symptom the previous release set out to remove, arriving through a
  different door, and a false success is worse here than an outright failure.
  `Get-DestinationWorkbook` now returns the unreadable workbook IDs to its caller, which
  records each as a failure so they reach the summary, the reports and the exit code.

- **The count an operator reconciles against is honest again.** `$total` was taken after
  the unreadable workbooks had been removed, so a destination with sixteen workbooks and
  five failures reported `from 11 bound to the destination workspace`. Both numbers were
  internally consistent and both were wrong, defeating the one check - comparing against
  the portal - that would have exposed the problem. It now counts what is bound.

- **An empty destination is no longer a hard failure.** If the bulk listing failed but the
  lightweight one legitimately returned no workbooks, the run threw "every individual
  fetch failed too" when none had been attempted, sending the operator after a permissions
  problem that did not exist. The failure is now conditional on there having been failures.

- **`Test-WorkbookScope.ps1` survives an unreadable workbook.** The content parse sat
  outside any `try`, and it throws on empty, whitespace or malformed input. A single
  workbook with no content - which the portal will happily create - ended the audit
  part-way through its table and produced no conclusions at all, precisely when it was
  being relied on. Such workbooks are now reported as `UNREADABLE` and the audit continues.

- **`Test-WorkbookScope.ps1` always explains itself.** A workbook that carried the
  migration tag but had not been scoped yet matched none of the reporting branches, so the
  most ordinary case of all - migrated workbooks, tool not yet run - printed a table, a
  horizontal rule, and nothing else before exiting non-zero. That case now has its own
  branch, and the branches are exhaustive.

- **`Test-WorkbookScope.ps1` no longer denies what it just observed.** If every workbook
  failed to read, it reported "No workbooks found bound to that workspace" - the opposite
  of the truth, since the listing had returned them.

- **`Test-ScopeConnection.ps1` no longer crashes on the condition it just diagnosed.** When
  `Get-AzAccessToken` returned nothing, the script printed `Objects returned: 0` and then
  called a method on `$null`, replacing its own diagnosis with a stack trace.

## [1.2.5] - 2026-09-01

### Added

- `tools/Test-WorkbookScope.ps1`, which reports for every workbook in the destination
  whether it is genuinely scoped to both workspaces, and when it is not, why.

  "Scoped" is not one condition. A query reaches its data by one of three routes -
  literal resource IDs on the query, a resource picker it points at, or the
  workbook-level `fallbackResourceIds` - and each fails differently. A workbook can be
  correct on one route and broken on another, which is what makes this present as
  "solution workbooks work and custom ones do not". The audit resolves every query by
  the route it actually uses and reports `OK`, `PARTIAL` or `NOT SCOPED` per workbook,
  with the reason. It is read-only.

### Changed

- A run now names the workbooks it is skipping, instead of only counting them.

  By default the tool updates only workbooks carrying a `MigratedFromWorkbookId` tag,
  which is to say the ones the Sentinel Migration Assistant created. Workbooks built by
  hand, and anything installed from a Content Hub solution, do not carry it and were
  skipped silently. The only signal was a count - `Found 3 migrated workbook(s) (from 16
  bound to the destination workspace)` - which is easy to read past, and whose
  consequence only appears later as some workbooks showing the old workspace's data and
  others not.

  The skipped workbooks are now listed by name, with the reason and the
  `-IncludeAllWorkbooks` switch that includes them, plus a note that a Content Hub
  solution update can revert its own workbooks.

## [1.2.4] - 2026-09-01

### Fixed

- A failure in the fallback listing no longer escapes unexplained. `Get-DestinationWorkbook`
  called the lightweight listing inside its catch block but not inside a nested `try`, so
  if that request also failed the exception propagated uncaught and the original error was
  discarded.

  That lost the most useful fact available. Whether the lightweight request succeeds is
  precisely what identifies the cause: if the bulk listing fails and the small one
  succeeds, the payload was the problem; if both fail, the amount of data is irrelevant and
  the fault is authentication or the network. The error now carries both failures and says
  which conclusion follows.

- Token validation no longer risks rejecting a valid token. The check introduced in 1.2.2
  demanded exactly three base64url segments, which would refuse a padded token or a
  five-segment JWE. Azure's ARM tokens are neither, so it worked - but the cost of being
  wrong was that the tool would refuse to run in an environment where it previously
  worked, and would blame the token while doing it.

  It now checks only what actually breaks an `Authorization` header: empty, whitespace, an
  unconverted `SecureString`, or a value that is not a JWT at all. A check added to make a
  confusing failure clearer should not become a new way to fail.

### Changed

- `tools/Test-ScopeConnection.ps1` now issues both listings - with and without workbook
  content - and reports the size and duration of each. Comparing them separates the two
  causes that produce the same 502:

  - both succeed: authentication and access are fine, look further into the run
  - only the bulk request fails: response size is the cause, and 1.2.3 or later handles it
  - both fail: not size; same token and route, so authentication or the network

  Measured against a live environment, the two requests are 1.3 MB and 13.7 KB. Previously
  the script issued only the bulk request, so it could report that something was wrong but
  not which of these it was.

- `Get-WorkbooksUri` builds its content query segment directly instead of rewriting the
  assembled URI with a regular expression.

## [1.2.3] - 2026-09-01

### Fixed

- Workbook discovery no longer fails outright when the bulk listing is rejected.

  The listing asks ARM for every workbook's `serializedData` in a single response
  via `canFetchContent=true`. Measured against a real environment, sixteen
  workbooks come back as **1.29 MB in one response**, with the largest single
  workbook at 807 KB. An intermediary unwilling to carry a body that size reports
  a gateway error, and the text accompanying it is often misleading.

  This is the same request the Sentinel Migration Assistant makes, and its code is
  identical - the two were diffed line by line across token acquisition, header
  construction, invocation, URI building and context handling, and no functional
  difference exists. What differs is the target: the migration assistant reads the
  *source*, while this tool reads the *destination*, which has accumulated every
  migrated workbook. Same request, considerably more payload.

  When the bulk listing fails, discovery now lists metadata only and fetches each
  workbook's content individually. The same listing drops to **13.7 KB**, and the
  largest single response becomes 807 KB rather than 1.29 MB. Slower, but it
  completes.

  A workbook that cannot be read individually is reported and skipped rather than
  losing the whole run, and the run fails loudly if nothing at all could be read -
  returning an empty set would look like a clean run that silently changed nothing.

- `Get-WorkbookUri` gained `-IncludeContent`. Without `canFetchContent`, a GET on a
  single workbook returns metadata and an **empty** `serializedData`. Verified
  against ARM: the same workbook returns 0 characters without it and 1548 with it.
  The first version of the fallback above missed this and would have recovered
  sixteen workbooks with no content in any of them - reporting success while
  scoping nothing. Caught by testing against live Azure rather than a mock.

## [1.2.2] - 2026-09-01

### Fixed

- The tool now checks its access token before sending it, instead of letting Azure
  reject a malformed `Authorization` header as an opaque HTTP 502.

  A customer run failed with `HTTP 502 ... Forbidden: Authentication information is
  not given in the correct format. Check the value of Authorization header.` on the
  workbook discovery call. The word *Forbidden* sent the investigation towards RBAC,
  and it was the wrong direction entirely - Azure never got as far as checking access.
  The header itself was malformed, which is a client-side fault.

  `Get-ScopeAccessToken` took whatever `Get-AzAccessToken` returned and interpolated
  it straight into the header. Three real conditions break that, and none of them
  produced a usable error:

  - An expired session returns nothing, giving a bare `Bearer`.
  - More than one loaded Azure context makes the cmdlet return more than one object,
    so the header holds two tokens separated by a space.
  - An unconverted `SecureString` renders as the literal text
    `System.Security.SecureString`.

  The token is now coerced to a single value, trimmed, and checked for JWT shape. Each
  failure names its own cause and the command that fixes it.

- A 502 carrying the authorization-header message is no longer retried. It is
  deterministic - the same bad header fails identically every time - so the three
  retries only added about fourteen seconds of backoff before the same failure. The
  error now explains that this is not a permissions problem.

### Added

- `tools/Test-ScopeConnection.ps1`, which reports PowerShell and Az.Accounts versions,
  how many Azure contexts are loaded, how many objects `Get-AzAccessToken` returns, the
  token's type, length, shape and expiry, and then performs the exact workbook read
  that fails. It prints no token material and only reads, so it is safe against
  production.

  When every token check passes and Azure still rejects the header, it says so and
  points at an inspecting proxy or TLS interception, which rules out the client rather
  than leaving it ambiguous.

### Changed

- Split the HTTP 502 troubleshooting entry in two. The same message is produced by a
  failed run and by a workbook failing to render in the portal, and the two have
  nothing in common. The entry now leads with how to tell them apart.

## [1.2.1] - 2026-09-01

### Fixed

- Re-scoping a self-healed workbook in literal mode now removes the injected
  Resource Graph parameter and every reference to it.

  1.2.0 changed the default to literal but only rewrote the scope lists. The
  injected parameter stayed in the workbook, kept its `isGlobal` flag, and went on
  being evaluated on every load - so a viewer without subscription-scope read kept
  getting HTTP 502 about the authorization header from a run that reported success.
  The customer who reported the original 502 upgraded, re-ran, and saw no change.

  A single `-Execute` in the default mode now repairs an affected workbook. No
  separate revert step is needed first.

  Cleanup falls back to reading the parameter item itself when the `$dualScope`
  manifest has been lost to a portal re-save, and is a no-op on workbooks that were
  never self-healed.

## [1.2.0] - 2026-09-01

### Changed

- **The default scope mode is now `Literal` again.** `SelfHealing` shipped as the
  default in 1.1.0 on the strength of documented Azure behaviour that had not been
  exercised against a live tenant. First contact disproved part of it.

  The mode injects an Azure Resource Graph parameter, and Resource Graph runs in the
  *viewer's* security context scoped to the source subscription. A viewer without
  read access at subscription scope receives HTTP 502 with a message about the
  authorization header. Because the parameter is marked global it is evaluated on
  every workbook load, so the whole workbook fails rather than one tile.

  The design assumed the parameter would resolve to an empty result when it could not
  see the workspace, and degrade gracefully. That holds when the workspace has been
  *deleted*. It does not hold when the caller lacks *permission*: Resource Graph
  returns an error, not an empty set.

  Literal mode issues no Resource Graph query, which is why the Sentinel Migration
  Assistant never produced this error.

- `SelfHealing` remains available and unchanged via `-ScopeMode SelfHealing`. It still
  removes the need to revert before decommissioning. Confirm every viewer has Reader
  on the source subscription first, and verify with `-ValidateQueries`.

### Documented

- Troubleshooting entry for HTTP 502 "check the authorization header", with the
  re-scope commands to recover affected workbooks.
- Guidance for tenants that require `Connect-AzAccount -UseDeviceAuth`, where access
  is commonly scoped below the subscription and literal mode is the safer choice.
- Corrected the permission claim throughout: Log Analytics Reader at workspace scope
  is enough to *read the data*, but not to satisfy a subscription-scoped Resource
  Graph query.

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
