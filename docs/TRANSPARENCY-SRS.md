---
artifact_id: artifact-2026-11-12-trano-transparency-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-12-trano-transparency
state: implemented
---
# Window background acceptance

| Requirement | Acceptance |
|---|---|
| FR-TRANSP-1 | Configured0.8 background opacity reaches top and bottom chrome, sidebar, pane header/padding/seams and empty workspace; classic opacity1 remains opaque; explicit legacy Glass styling retains its own tint. Foreground text/icons and NSWindow alphaValue remain1. |
| FR-TRANSP-2 | Renderer and native container/padding do not paint over one another; a configured0.8 terminal background remains0.8 rather than0.96. Terminal/profile colors, image alpha and ANSI rendering remain correct. |
| FR-TRANSP-3 | Standard native behind-window material spans the whole main window including footer; opaque/classic mode and existing layout geometry remain valid. |
| FR-TRANSP-4 | Existing local font/size/palette/opacity are applied without executing Lua or changing original configs, credentials, running shell PIDs or workspace/tab/pane layout; private backup and read-only check receipt retained. |
| FR-TRANSP-5 | Appearance and profile controls accept the inclusive0–100% range. Native continuous slider changes repaint default-pane and whole-window background immediately without persisting a draft; Cancel/unmount restores the latest stored setting. Foreground alpha and explicit profile opacity remain unchanged; zero hides native material. |

| Component | Behavior |
|---|---|
| InterfaceContext / Presentation | Background opacity propagation and separate chrome/pane alpha |
| Workspace / Interface effects | Background-only tint and one whole-window material; no child foreground dimming |
| Native container | Fill exposed anchoring gaps only, never behind terminal child |
| Tests | Native alpha samples at1x/2x, synthetic pane gap/padding, profile/image/renderer regression; no real terminal jobs |
