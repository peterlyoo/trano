---
artifact_id: artifact-2026-11-14-trano-input-ergonomics-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-10-agent-terminal-m2
state: closed
last_updated: 2026-11-16
---
# Workspace search and editable paste

| ID | Priority | Acceptance |
|---|---|---|
| FR-SEARCH-1 | P0 | Cmd+K workspace search also matches the Latin keystrokes represented by Korean two-set input, including composed Hangul, compatibility jamo, shifted consonants/vowels and mixed ASCII/punctuation. Preserve literal matching and stable workspace order within matching tiers; do not change the input source or typed query. Filtering includes the full visible query, including active native Hangul preedit, and matches contiguous case-insensitive substrings so displayed `개ㅛ` (`roy`) matches `project-roy-dev` without matching `proxysql`. Session search previews marked text via `previewsMarkedText` without replacing marked text in `updateNSView`, while the `Up`/`Down`/`Enter` guard retains native input method ownership of composition and submit. |
| FR-SEARCH-2 | P0 | Literal Korean workspace names, native IME composition, row identity, Up/Down/Enter navigation and context actions remain intact. Named Create/get-or-create uses the exact original trimmed input, never a converted candidate. Query transformation is local and deterministic, with one scalar pass and output linear in input length; no separate query-length cap or measured latency guarantee is introduced. |
| FR-PASTE-EDIT-1 | P0 | Multiline preview is a native editable plain-text field. Paste sends the final edited Unicode content exactly once; Cancel/Escape sends nothing. Clipboard contents remain unchanged. |
| FR-PASTE-EDIT-2 | P0 | Return/keypad Enter inside the editor inserts a newline or performs the input method's composition action. Return outside the editor activates Paste. Confirmation keys never append a terminal submit byte. Native focus and button clicks use the same final action. |
| FR-PASTE-EDIT-3 | P0 | After confirmation, revalidate original pane/window/provider ownership, final UTF-8 payload size at most 1 MiB and current bracketed-paste mode. Editing, cancellation, newer intents and stale owner changes cannot bypass existing input protection. |
| FR-CHROME-FOOTER-1 | P0 | Remove Persistent sessions, live count, host label and the entire 27pt footer/separator; workspace content reaches the window bottom across toolbar positions, sizes and sidebar visibility. Preserve configured whole-window opacity and running sessions. |

## Implementation boundaries

| Surface | Existing/planned ownership |
|---|---|
| Search | Existing `PickerView` in `Sources/TranoApp/WorkspaceView.swift`; pure `Sources/TerminalCore/KeyboardLayoutSearch.swift`; only session-picker matching consumes the alternate query |
| Paste | Existing `TerminalDraftPaste` and native presenter in `Sources/TranoApp/TerminalDraftPaste.swift`, called by `TranoView.pasteDraft`; retain the original deferred input ownership through modal editing |
| Native preview | NSTextView editing and native responder routing; no global Return interception or terminal keyboard changes |
| Footer | WorkspaceView root and populated TerminalPane viewport; remove the footer without an empty band, keep the default renderer and its hit region at the pane bottom, and preserve explicit padding/bottom anchoring |

## Verification

| Layer | Required evidence |
|---|---|
| Pure | Two-set decomposition, mixed text, literal fallback, deterministic bounded matching and final edited-text size/ownership checks |
| Native components | Actual Cmd+K search field, result navigation and stable IDs; existing activation closures remain unchanged; IME remains owned; constructed native alert/editor/button events; exact bracketed output; no auto-submit; final footer geometry and captures |
| Installation | Release build, Apple Development signature, running GUI/helper/API identity, file hashes and unchanged shell PIDs/layout/settings |
| Limits | Physical OS IME/provider/PTY/SSH E2E remains paused by user; native no-job unit fixtures only; no claim of whole-product qualification |

The original M2 FR-INPUT-3 safe-paste contract remains in force. No new external API, dependency, provider invocation or keyboard-source preference is introduced.

Targeted verification passed 66 product units and 45 packaging units. Native alert tests use separate events for Return and keypad Enter. Initial confirmation tests verify Paste without forcing button focus; editor-to-button tests explicitly transfer native focus before verifying Return. They preserve marked text for the editor. Pre-order initialFirstResponder configuration and the guarded makeFirstResponder call do not establish displayed-modal focus; physical modal activation and OS IME qualification remain paused.
