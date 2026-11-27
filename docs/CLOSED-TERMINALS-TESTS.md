---
artifact_id: artifact-2026-11-16-trano-closed-terminals-tests
artifact_type: test-suite
parent_id: artifact-2026-11-16-trano-closed-terminals-srs
state: reflected
version: 1
authors: [codex]
last_updated: 2026-11-16
traceability_to: [artifact-2026-11-16-trano-closed-terminals-srs]
---

# Test Suite Specification: Closed Terminals

> **Summary**: Specifies unit, fake-transport, and inert fixture test cases covering capture, termination, restore, and failure handling without disturbing live user sessions.

## Test Cases: Unit, Fake Mux/Transport, and Inert Native Fixtures

| Case ID | Traces To | Scenario | Expected Result |
| :--- | :--- | :--- | :--- |
| TC-CLOSE-01 | FR-CLOSE-1 | Snapshot failure on pane *k* before kill | Close aborts; zero processes terminated; workspace layout and metadata unchanged. |
| TC-CLOSE-02 | FR-CLOSE-2 | Stop failure on *n*th pane & retry idempotency | `closing` state persisted before kill; captured archives retained; retry cleanly finishes stop without duplicate LIFO entries. |
| TC-CLOSE-03 | FR-CLOSE-2, FR-CLOSE-7 | Legacy supervisor rewrites `RuntimeContinuity.swift` & crash recovery runs | Sidecar survives rewrite; `Recovery.swift` does not auto-restore intentionally closed tabs/panes. |
| TC-CLOSE-04 | FR-CLOSE-3, FR-CLOSE-7 | Shell kind, immutable launch args, history import, and ANSI sanitization | Restores recorded shell (not hardcoded `zsh`); strips unsafe controls (>10,000 lines / 4 MiB truncated); imports history without `eval`/execution; ignores arbitrary startup commands. |
| TC-CLOSE-05 | FR-CLOSE-3 | LIFO restore with moved sibling panes | Restores closed pane topology in LIFO order (max 20) without stealing or duplicating live moved siblings. |
| TC-CLOSE-06 | FR-CLOSE-4 | Provider conversation resume & account/org mismatch | Resumes exact conversation under fresh generation after old-process exit; on account/org mismatch or outage, opens fresh shell with recovery record and zero duplicate submissions. |
| TC-CLOSE-07 | FR-CLOSE-3, FR-CLOSE-5 | Stale close context, history provenance metadata, and truthful close UI labels | Rejects close/restore on mutated target identity; records unhooked shell history provenance metadata as on-disk fallback rather than exact memory capture; UI labels truthfully describe close behavior. |
| TC-CLOSE-08 | FR-CLOSE-6 | Remote helper capability gate, lock scope, and ambiguous SSH response | Rejects unsupported remote helper safely; performs SSH outside local state lock; reconciles timeout without losing snapshot. |
| TC-CLOSE-09 | FR-CLOSE-2, FR-CLOSE-7 | Interrupted close retry and failed/full process census | Original witnesses retained; incomplete capture fails before kill. |
| TC-CLOSE-10 | FR-CLOSE-3 | Second-pane restore failure or interrupted fresh-shell save | Successful shell retained; retry creates only the missing shell and deduplicates topology. |
| TC-CLOSE-11 | FR-CLOSE-6 | Prepared remote cancellation and committed remote/local-validation failure | Untouched preparation discarded; acknowledged stop reconciled into recoverable saved state. |
| TC-CLOSE-12 | FR-CLOSE-2, FR-CLOSE-5 | Floating Cmd+W versus native red-close; stale monitor startup | Explicit shortcut stops fake backend, native red-close returns view, immutable PID guards monitor callbacks. |

## Verification Limits and Live-Session Safety
- **Unit & Inert Scope Only**: Because the user paused E2E testing, verification executes exclusively via pure unit tests, fake mux/transport harnesses, and inert native fixtures.
- **Live Terminal Protection**: Tests and signed build/install checks must never signal or kill any existing user terminal process; pre/post verification snapshots must confirm all live user shell PIDs, layouts, and settings remain intact.
- **Unqualified Real Integrations**: Real Claude/Codex provider resume, live SSH `remote/main.go` execution, and real PTY shell hook integration remain explicitly not run in this milestone.

## Installed Verification — 2026-11-16

| Evidence | Result |
| --- | --- |
| Focused Swift / Go gates | 116 Swift units; 44 fake/pure Go race tests; no failures |
| Source binding | 50 closed-feature source/test hashes unchanged after unit verification; later source changes limited to separately tested IME repair |
| Independent reflection | Claude rival accepted; `.local/closed-terminal-state/{final-review,unit-receipt}.json` and `.findings/final.md` |
| Signed local installation | Apple Development; 8a3bf2453d1e2a3144d7a08dd81dfc766af39e890180b513afa04c327e2f0909; 129 bundle hashes; GUI/helper/API identity verified |
| Continuity | 63 live shell PIDs, layout/settings and 4 preference sidecars preserved; `.local/closed-terminal-state/installed-receipt.json` |
| Qualification limits | On-disk fallback for legacy unhooked shell history; remote helpers packaged, not deployed; real PTY/provider/SSH/GUI E2E paused |

Native history encoding amendment (2026-11-16):zsh/bash archives preserve nonUTF8 native bytes as Data;UTF8 is required only for fish. Ownership,no-follow,NUL,size/entry bounds and import-as-data safeguards remain. Seven encoding regressions and21 lifecycle tests pass;actual user history was read for byte metadata only and was not modified.
