---
artifact_id: artifact-2026-11-13-trano-unisession-sdd
artifact_type: sdlc-sdd
parent_id: artifact-2026-11-13-trano-unisession-srs
state: implemented
---
# Unisession design

One detached backend and one retained native renderer move between workspace anchors. Workspace layout never owns this terminal.

| Requirement | Owning implementation | Behavior |
|---|---|---|
| FR-UNI-1 | TerminalCore/Unisession.swift, UnisessionRuntime.swift, UnisessionStateStore.swift | Use the focused local directory or local home when the active pane is remote. Runtime transaction serializes ensure; publish a reserved UUID before creating a shell; validate exact PID and OS birth identity; retain retired ownership; adopt safe live legacy binding. |
| FR-UNI-2, FR-UNI-3 | TranoApp/UnisessionController.swift, UnisessionPresentation.swift, UnisessionWorkspaceAnchor.swift | One external AppStore and NSHostingView retain the same TranoView/DeveloperTerminalContainer. Native anchor converts actual terminal-workspace bounds into the parent content view; pointer events outside the overlay pass through. |
| FR-UNI-3 | StartupWorkspace.swift, Recovery.swift, DecisionInbox.swift, ConversationResume.swift | Combined reservations prevent generic orphan adoption, restoration or ordinary attach. Resume returns to an active shared agent; ended/dead conversations use normal resume. |
| FR-UNI-4 | TranoApp/ExternalTerminalPanePolicy.swift, UnisessionController.swift | Project only the shared pane, reuse TerminalPane/theme preferences and a common pane opacity, apply local zoom to the copied profile without saving global settings. |
| FR-UNI-5 | TranoApp/UnisessionFocusIntent.swift, UnisessionController.swift, App.swift | Exact owner/responder/generation guards async focus. Native child Find editors belong to the same surface but keep native editing. Reparent/hide respects marked text and modal input; passive same-owner layout does not revoke interaction leases. |
| FR-UNI-6 | Tests/TerminalCoreTests/Unisession*; Tests/TerminalUITests/UnisessionTests.swift | Fake backend/file tests and native components only. Signed actual installation verifies existing PID/layout/settings continuity; E2E remains paused. |

The existing toolbar raw identifier `supervisor` remains compatible with saved visibility preferences; its visible title and control open Unisession. Legacy Supervisor API modules remain available without exposing their dashboard through this control.
