---
artifact_id: artifact-2026-11-12-trano-resume-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-12-trano-resume
state: implemented
---
# Resume acceptance and component contracts

| Requirement | Acceptance | Owner |
|---|---|---|
| FR-RESUME-1 | Bounded read-only Claude/Codex history discovery validates UUID/provider metadata and retains source account/root; malformed, symlink, traversal and wrong-identity records are rejected. | ConversationHistory.swift |
| FR-RESUME-2 | Search title/cwd/account/ID and provider filter; newest-first stable selection; native arrows/Enter and Hangul composition; clear loading/empty/error states. | ConversationResumePicker.swift |
| FR-RESUME-3 | Header/palette/configurable Cmd+Shift+R opens contained native overlay; outside/Escape dismiss without viewport resize; native modal/IME/window ownership gates. | App/Store/Workspace |
| FR-RESUME-4 | Resume revalidates exact source transcript ID/root/cwd/account and opens a new tab in captured workspace; same active conversation opens its existing pane; reserved Supervisor retains native ownership. | ConversationResume runtime |
| FR-RESUME-5 | No current-pane send, job termination, credentials/history copying or prompt replay; duplicate/stale actions cannot launch another conversation; only a newly created failed pane is rolled back. | Runtime/Store |
| FR-RESUME-6 | Synthetic history/fake operations/native component units pass; signed local installation preserves current shell PIDs/layout; real provider/PTY/E2E remain unrun. | Root |

## Shared model

- ConversationHistorySource: id:String, provider:AgentKind, configurationRoot:String, accountID:String?, label:String, enabled:Bool.
- AgentConversation: id computed source.id + providerSessionID, source:ConversationHistorySource, providerSessionID:String, title:String, cwd:String, updatedAt:Date, relativePath:String.
- ConversationHistorySnapshot: conversations:[AgentConversation], warnings:[String], truncated:Bool.
- ConversationHistoryIndex.discover(sources:limits:cancelled:): snapshot; no real private-history reads in development.
- ConversationHistoryIndex.validate(conversation:): freshly parsed matching AgentConversation or error; callers may not trust a stale picker row.
- UI row/model owns only display/search/selection/loading/busy state; injected root callbacks own loading and activation.

## Unit strategy

| FR | RED/GREEN fixtures |
|---|---|
| 1 | Synthetic Claude summary/user/cwd and Codex session_meta/event titles; account collisions; symlinks, wrong UUID, oversized/malformed lines; bounded traversal/cancel |
| 2–3 | Real offscreen native controls with fake callbacks; search/filter/selection; IME; keyboard and outside/Escape; parent viewport containment |
| 4–5 | Pure plans/fake operations; exact argv and cwd/account; active reuse, duplicate selection, stale workspace/source/account, fresh generation, created-pane-only rollback |
| 6 | Selected main units and package checks; signed build and installation receipts |

Supervisor ownership applies to the reserved pane and any exact retained launch mapping. Explicit Supervisor Stop releases its launch; manually selecting its historical conversation can create a new ordinary pane while preserving the reserved pane identity. Active or uncertain retained launches open their existing pane even when their provider has yielded the foreground terminal.
