---
artifact_id: artifact-2026-11-12-trano-supervisor
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implemented
---
# Native Supervisor

The visible Supervisor dashboard has been superseded by [Unisession](UNISESSION.md). This document records the retained legacy backend/API contract; the toolbar now opens one shared ordinary terminal.

Keep a dedicated supervision surface visible across workspace navigation, with a Supervisor icon beside EasyDecision. Adapt the inspected rex-supervisor workflow through Trano APIs; private scripts and organization-specific integrations stay outside the product.

| Requirement | Acceptance |
|---|---|
| FR-SUP-1 | App-global native tool panel retains the same supervised terminal/session across workspace switches; toggle does not stop the background job or resize the main terminal. |
| FR-SUP-2 | Explicit Start launches a managed Claude/Codex supervisor with bundled Trano-native instructions and immutable pane identity; reopening attaches the same live job. |
| FR-SUP-3 | Event-driven state covers working, done, blocked, quota limits and decisions; self is excluded; safe send requires idle state and empty input, with no arbitrary suggestion submission. |
| FR-SUP-4 | Decisions enter existing native decision flow; production/destructive/shared actions need explicit user decisions; no hardcoded private Slack/host/path data. |
| FR-SUP-5 | Deterministic headless state/action surface and native action use one durable local state contract; PID/layout and UI persistence tests are required. |

Existing managed-account switching, agent resume identity and background process persistence remain authoritative. Native implementation must not start live supervision merely while building or testing the app.

## Current implementation and unit evidence

**The native Supervisor panel persists across workspace navigation and requires explicit agent startup.** Reopening the panel attaches to its retained binding. Private socket bootstrap validates the nonce, pane, and PID birth identity before directly executing the managed argv. To prevent unintended input, Supervisor never automatically sends a continuation without trusted empty-input evidence, requiring review instead. The native helper app includes `Trano.icns` and `CFBundleDisplayName` `Trano`. No live provider, PTY/bootstrap IPC, OS notification presentation, or physical persistence qualification has been run.

| Evidence | Result |
|---|---|
| Installed build | `c6b3e574ce453eb1b29691009e94a54f698dabe6fcab3fc332cd471a2a2ddb0a`; Apple Development signature verified |
| Continuity | 21 existing shell PIDs and exact workspace/tab/pane layout retained |
| Binary identity | Running GUI/helper paths, helper API build identity and 123 built/installed file hashes verified |
| Unit tests | 226 core XCTest +285 native XCTest +26 Swift Testing =537;0 failures |
| Packaging units | 26 passed;0 failures |
| Artifacts | `.local/settings-release-unit.log`, `.local/settings-packaging-unit.log`, `.local/settings-installed-receipt.json` |
