---
artifact_id: artifact-2026-11-13-trano-unisession-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-13-trano-unisession
state: implemented
---
# Unisession acceptance

| ID | Priority | Acceptance |
|---|---|---|
| FR-UNI-1 | P0 | All workspaces share exactly one durable detached terminal binding. Concurrent opens reuse it; PID/generation mismatch fails safely; dead shells can be recreated without replaying commands. |
| FR-UNI-2 | P0 | Unisession replaces the visible Supervisor control/dashboard with a plain terminal overlay anchored upper-right inside the active Trano window. No provider/account/start/stop/target form. |
| FR-UNI-3 | P0 | Workspace switches and eligible window switches preserve the same session and renderer. Hide, workspace close and GUI relaunch preserve backend jobs; the shared pane is excluded from generic workspace adoption. |
| FR-UNI-4 | P0 | Body and compact header use resolved Trano theme/background/foreground/font/opacity. Overlay fits small windows, resizes and expands/restores, while leaving workspace terminal layout unchanged. |
| FR-UNI-5 | P0 | Input/IME, paste, keyboard focus and close/zoom actions target the shared renderer correctly. No remount steals marked text or native modal input. |
| FR-UNI-6 | P0 | Pure/fake/native units pass; signed installation preserves current shell PIDs/layout/settings. E2E remains paused, with physical qualification explicitly unverified. |
