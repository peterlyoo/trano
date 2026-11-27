---
artifact_id: artifact-2026-11-13-trano-server-status
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implemented
---
# Background server visibility

The existing Trano Service helper will expose its verified server state in the macOS menu bar. Terminal sessions continue independently of API recovery. Quit Server provides an explicit recovery path when an old helper cannot expose its shutdown API.

| Scope | Contract |
|---|---|
| Branding | The menu-bar item uses the Dock snake wordmark alone as a white template vector, preserving its proportions and eye cutout. The background tile is omitted; state remains in the menu, tooltip and accessibility label. |
| Status | Starting, Running, connection error, startup error and restarting have distinct cached presentations. Running requires the current PID/build/background identity from server.info. |
| Recovery | Open Trano, Retry Connection, Restart Server and Quit Server use the existing helper. Restart replaces the API listener without killing terminal jobs. |
| Diagnostics | server.info exposes cached status-item registration and health metadata. Failure remains visible in the helper menu. |
| Qualification | Pure and native-component unit tests only; E2E remains paused. Actual signed local installation verifies PID/layout/settings continuity. |

Requirements and acceptance are in [SERVER-STATUS-SRS.md](SERVER-STATUS-SRS.md). Execution ownership is recorded in `.local/server-status/brief.md`. A whole-helper crash removes its own menu item; an independent watchdog is outside this slice.
