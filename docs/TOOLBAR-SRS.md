---
artifact_id: artifact-2026-11-12-trano-toolbar-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-12-trano-toolbar
state: implemented
---
# Toolbar acceptance contract

| Requirement | Acceptance |
|---|---|
| FR-TOOLBAR-1 | All eight action icons expose the direct native Customize View menu on right-click and Control-click, including conditionally present reset tickets and disabled primary actions. Normal left-click passes to the original action. |
| FR-TOOLBAR-2 | Checked per-action choices hide/show only the corresponding toolbar entry without altering shortcuts, layout, live sessions or an already open feature. Horizontal and vertical layouts consume the same visibility settings. |
| FR-TOOLBAR-3 | Visibility persists across restart in the private sidecar; legacy settings default to visible; concurrent changes to other icons/settings survive. |
| FR-TOOLBAR-4 | Existing tab/blank-header Customize View submenu can restore every hidden item, including when all action icons are hidden. Native window/composition/modal guards remain. |

| Component | Behavior |
|---|---|
| InterfacePreferences / Draft | hiddenToolbarItems string-ID set; bounded decoding/validation; per-ID three-way merge |
| HeaderContextMenu | Shared checked item menu; direct root for icons, existing submenu for tab/background |
| WorkspaceView | Context-only native region and conditional removal for each action; common horizontal/vertical builder |
| Tests | Synthetic legacy/persistence/concurrency; actual mounted native regions and menu actions; no live PTY/provider fixtures |
