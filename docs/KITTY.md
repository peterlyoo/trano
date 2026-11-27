---
artifact_id: artifact-2026-11-12-trano-kitty
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implementing
---
# Kitty clipboard and URL hints

Provide OSC 5522 clipboard interoperability and keyboard selection of visible URLs without interrupting running terminals. Existing PRD U01–U21 remain in scope.

- Protocol source: https://sw.kovidgoyal.net/kitty/clipboard/
- Hint behavior: https://sw.kovidgoyal.net/kitty/kittens/hints/
- Implementation: pinned SwiftTerm protocol/Apple bridge; native Trano host permissions and viewport overlays.
- Acceptance: [SRS](KITTY-SRS.md), [external wire contract](KITTY-IDD.md), [RTM](RTM.md).
- Unit verification: 16 native clipboard, 7 native URL-hint, 5 pure URL-matcher and 4 key-binding tests passed. Native fixtures use private pasteboards, fake delegates and injected URL openers.
- Default URL-hint shortcut: Ctrl+Shift+E; letters select visible HTTP(S) URLs. Escape and outside click dismiss the overlay.
- E2E is paused at user request. Actual PTY/tmux transport, physical clipboard/IME and OS pointer behavior are not newly qualified; the optional fixture remains unrun.
- Clipboard reads require permission and revalidate the owning terminal after the decision. Primary clipboard is unsupported. Already accepted in-flight host writes during backend replacement are not claimed to be fully canceled.
