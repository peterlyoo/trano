---
artifact_id: artifact-2026-11-12-trano-resume
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implemented
---
# Native conversation resume

Find previous Claude/Codex conversations by title, project, provider and account in a native terminal overlay. Resume opens a new tab in the captured workspace; an already active exact conversation opens its existing pane. Existing terminal jobs, credentials and conversation files remain unchanged.

| Decision | Contract |
|---|---|
| Access | Header history icon, configurable Cmd+Shift+R, Command Palette |
| Sources | Default/environment provider roots, registered account roots, previously recorded local launch roots |
| Selection | Provider icon, title, original folder, account, modified time; All/Claude/Codex filter; arrows/Enter/Escape/outside dismissal |
| Activation | Exact UUID and file metadata revalidation; original cwd/root/account; no --last or prompt replay |
| Missing/invalid data | Visible error; picker stays open; no cwd/account fallback |
| Verification | Synthetic filesystem and fake launch unit tests; native components; E2E paused |

## Closed terminal reopen

`Cmd+Shift+T` (`Reopen Closed Tab`, `client.tab.restore`) restores explicitly closed terminals and is distinct from the conversation picker `Cmd+Shift+R`. Because explicit close terminates the backend process—unlike floating-window native red close, app or window close, workspace hide, or pane/tab moves, which keep jobs running—reopen creates fresh same-kind shells at the original `cwd` across the saved topology, restoring sanitized display/scrollback and imported available native history as non-executed data.

Captured Claude or Codex sessions resume only with their exact original provider, account, and organization context, never using `--last` or prompt replay. If binding context is unavailable or the conversation is already active elsewhere, reopen yields a fresh shell with actionable recovery and MUST NOT start a duplicate conversation. Verification for this explicit-close change is limited to pure/fake and inert native-component tests; remote helper deployment and live SSH, provider, or PTY qualification remain unrun. See [Closed terminal contract](CLOSED-TERMINALS.md).

## Installed verification

| Evidence | Result |
|---|---|
| Selected product units | 249 core XCTest +294 native XCTest +26 Swift Testing =569 passed;0 failures; `.local/native-resume-stage/final-unit.log` |
| Final owner correction | 54 targeted units passed after floating presentation-owner update; `.local/native-resume-stage/owner-final-unit.log` |
| Packaging units | 26 passed;0 failures; `.local/native-resume-stage/packaging-unit.log` |
| Signed build | `8c00b3fb79d68ec935aba37b15936854e9d47f8d6243c1d9721190d26d25a596`; Apple Development; release build106.80s |
| Installation | `/Applications/Trano.app`;21 existing shell PIDs and exact layout preserved;123 built/installed file hashes matched |
| Receipt | `.local/native-resume-stage/installed-receipt.json`; GUI/helper paths and helper API build identity verified |
| Discovery scope | Up to32 sources,10,000 visited entries,256 files,16MiB read budget,200 conversations; partial results are labelled |
| Open qualification | Real provider/PTY resume, physical GUI/IME and live remote history remain unrun; E2E paused by user |
