---
artifact_id: artifact-2026-11-13-trano-tool-panels-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-13-trano-tool-panels
state: closed
version: 1
last_updated: 2026-11-13
---
# Tool panel acceptance

| Requirement | Priority | Acceptance |
|---|---|---|
| FR-PANEL-1 | P0 | Activity, Queued Input, Decisions, Resume, palette/workspace picker, utility dialogs and Unisession chrome resolve the existing interface light/dark/tint colors without per-feature dark forcing. |
| FR-PANEL-2 | P0 | Tool title/header/close use 13/40/24 points; content inset16, section gap12, body12, corner8 and one shared border/surface treatment. Functional widths and terminal-specific configuration remain. |
| FR-PANEL-3 | P0 | Settings, Profiles, Accounts/organization, Remote Hosts/Paths, Extensions and Voice use the same themed chrome; defaults are current interface settings, with no new persistence. |
| FR-PANEL-4 | P0 | Theme changes repaint open consumers; native controls keep text/edit selection and do not mutate session/queue/decision/provider state. |
| FR-PANEL-5 | P0 | Existing outside/Escape/Close/Cancel guards, draft rollback, nested owner handling and Unisession renderer identity pass regressions; signed replacement preserves live PIDs/layout/settings. |

Evidence: `ToolPanelDesignTests`, existing native dismissal/IME suites, safe unit scope and installed receipts under `.local/tool-panel-design/`; physical E2E remains paused.

Coverage limits: the13-root rendering matrix mounts the command picker; the workspace-picker branch and automatic OS appearance → Unisession controller/anchor propagation are verified by source review. Unisession chrome is unit tested through its native surface; these checks do not qualify physical OS appearance events. Capture export is opt-in with `TRANO_TOOL_PANEL_CAPTURE_DIR`; pixel assertions always run.
