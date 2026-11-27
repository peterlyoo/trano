---
artifact_id: artifact-2026-11-13-trano-unisession
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implemented
---
# Unisession shared terminal

Unisession replaces the Supervisor dashboard with one ordinary terminal shared across every Trano workspace. It sits inside the active workspace window at the upper-right and uses the same terminal theme, font and window transparency.

| Scope | Behavior |
|---|---|
| Open | One toolbar action opens the existing shared shell or lazily creates it in the current local directory. No agent/provider setup form. |
| Continue | Workspace and window changes move the same renderer; hide and window close retain the backend session. |
| Appearance | Compact title, terminal body, hide and expand controls follow existing Trano presentation. |
| Compatibility | Legacy API contracts remain available; a safe live Supervisor session is reused when migrating. |
| Qualification | Pure/fake/native components only; real E2E remains paused. Signed local installation preserves existing jobs/layout/settings. |
