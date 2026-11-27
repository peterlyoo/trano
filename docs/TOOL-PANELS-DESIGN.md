---
artifact_id: artifact-2026-11-13-trano-tool-panels-design
artifact_type: sdlc-sdd
parent_id: artifact-2026-11-13-trano-tool-panels-srs
state: closed
version: 1
last_updated: 2026-11-13
---
# Shared panel rendering

| Requirement | Owning implementation |
|---|---|
| FR-PANEL-1/4 | `ToolPanelTheme` consumes `InterfacePreferences.resolve` using current resolved pane colors and interface scheme; no new theme authority. |
| FR-PANEL-2/3 | `ToolPanelHeader`, `ToolPanelCloseButton`, `toolPanelSurface`, native equivalents and one metrics table replace feature literals. Opaque utility surfaces preserve existing readability. |
| FR-PANEL-5 | Presentation/lifecycle/input authority remains with existing owners; native scroll containers stop painting an independent system background. |
| Coverage | Toolbar direct tools, workspace actions, banked-reset Accounts destination, settings/profiles/nested organization/remote paths, queued input and Unisession header. |
| Ownership | Root integrates immutable private worker patches, compiles serially, inspects actual offscreen captures and installs the signed bundle with continuity assertions. |

| Rendering detail | Constraint |
|---|---|
| Separate native hosting roots | Explicitly inject the same theme; retain the existing host/draft instance during updates. |
| Native controls | Paint/font updates precede text/IME equality guards; do not rewrite text, selection or undo. |
| Background painters | Fill only `bounds.intersection(dirtyRect)`; verify actual header ink, not only marker geometry. |
| Multiline organization text | Measure against the existing460pt control width; actual host remains below500pt in all three theme modes. |
| Native Close |24pt intrinsic size and zero alignment insets; exact guarded callback and teardown remain owned by existing flows. |
