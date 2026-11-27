---
artifact_id: artifact-2026-11-12-trano-session-load
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implemented
---
# Session load visualization

Show per-session resource load and hook latency alongside activity, using cached coarse local metrics. AgentBoost source contracts inform hook-p99 mapping without reading prompts or transcripts.

| Requirement | Acceptance |
|---|---|
| FR-LOAD-1 | CPU percentage, resident memory and optional hook p99 are bound to session/backend identity; unknown/stale values remain distinct from zero. |
| FR-LOAD-2 | Samples aggregate only owned process descendants; PID reuse and terminated jobs cannot inherit another process's samples. |
| FR-LOAD-3 | Compact per-session bars/history render from cached state; main-thread clicks do not trigger process scans or telemetry imports. |
| FR-LOAD-4 | Fake process/clock/telemetry unit tests prove rates, identity, freshness and bounded work; live E2E is deferred by user instruction. |

Quota notification acceptance belongs to the native settings parity contract; quota-reset and low-quota switches must gate actual notification dispatch and persist through restart.

## Current implementation and unit evidence

**Session load surfaces cached per-pane CPU/RSS and optional trusted Claude hook p99 metrics in Activity and Supervisor.** Resource metrics sample every 2 seconds, and hook tails sample every 30 seconds. The `sessions.load` API reads from cache only, ensuring click and frame paths never probe processes or scan logs. Unknown values remain unknown. Numeric hook collection reads bounded, validated tails without exporting prompts. Live accuracy and runtime performance remain unqualified.

| Evidence | Result |
|---|---|
| Installed build | `c6b3e574ce453eb1b29691009e94a54f698dabe6fcab3fc332cd471a2a2ddb0a`; Apple Development signature verified |
| Continuity | 21 existing shell PIDs and exact workspace/tab/pane layout retained |
| Binary identity | Running GUI/helper paths, helper API build identity and 123 built/installed file hashes verified |
| Unit tests | 226 core XCTest +285 native XCTest +26 Swift Testing =537;0 failures |
| Packaging units | 26 passed;0 failures |
| Artifacts | `.local/settings-release-unit.log`, `.local/settings-packaging-unit.log`, `.local/settings-installed-receipt.json` |
