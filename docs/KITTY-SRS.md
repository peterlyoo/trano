---
artifact_id: artifact-2026-11-12-trano-kitty-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-12-trano-kitty
state: implementing
---
# Kitty behavior contract

The clipboard wire protocol uses existing SwiftTerm parsing; URL hints are a Trano input overlay. Physical screen and remote multiplexer qualification must be reported separately from native fixtures.

| Requirement | Acceptance |
|---|---|
| FR-KITTY-1 | Standard clipboard MIME enumeration/read and atomic multi-representation write; base64/chunk/alias/id/error handling per official OSC5522 contract; primary returns ENOSYS. |
| FR-KITTY-2 | Reads require native user permission except listing or valid user-paste token; optional per-TTY password grants follow protocol; hidden/stale hosts deny; tests never use the real clipboard. |
| FR-KITTY-3 | DECRQM reports support only when full standard services exist; DECSET/DECRST5522 paste events use one-time grants and reset correctly; existing safe text/image paste remains. |
| FR-HINT-1 | Ctrl+Shift+E and Command Palette open distinct hint labels on visible http(s) URL text, including wrapped/Unicode cells; no terminal resize or PTY input. |
| FR-HINT-2 | Typing filters labels, complete label opens exact URL, Escape/outside dismiss and Backspace revises; marked text, stale pane/generation and overlays preserve input/ownership. |

## Design and tests

- Clipboard: TerminalBridge explicit capabilities/permissions; native pasteboard service, SwiftTerm protocol engine, configured terminal options and mode-aware paste hook.
- Hints: pure visible-cell matching and labels, native terminal-local drawing/event handler, shared action registry.
- Tests precede implementation and declare requirement IDs; native send/feed responses and frame/keyboard tests qualify core behavior.
- No new package version or global font/clipboard preference changes.

Hidden-label OSC8 hint selection is a separate Kitty mode and is not claimed by visible URL hints.
