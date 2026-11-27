---
artifact_id: artifact-2026-11-13-trano-batch-completion-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-13-trano-batch-completion
state: implemented
---
# Organization-aware managed profiles

Claude profiles may share a login account while selecting different organizations. Organization configuration and verified identity belong to each managed profile, independently of the human account label and quota cache.

| ID | Acceptance |
|---|---|
| FR-ORG-1 | Each managed Claude profile can select an organization UUID and optional display name, or leave organization unbound. Choices can reuse known profile organizations. Existing profiles remain unbound without migration or credential changes; Codex profiles reject Claude-only organization binding. |
| FR-ORG-2 | Configure Claude's documented `forceLoginOrgUUID` and claude.ai method only inside that owned profile's settings/launch inputs, retaining unrelated settings, managed activity hooks, MCP and extensions. Do not claim that a user-level preference enforces provider membership. |
| FR-ORG-3 | Parse bounded provider `auth status` metadata from the exact managed configuration root; retain only organization UUID/name and verification state/time. A mismatched or missing organization is explicit and cannot be treated as a selected verified organization or silently launch/switch under a different organization. Same-account profiles retain distinct IDs, roots, quota caches and order. |
| FR-ORG-4 | Native account controls show configured and observed organization states and support select/clear/refresh without blocking the main thread. Provider sign-in remains its existing explicit native terminal action. Account generation, conversation/account resume and same-provider switch guards preserve existing behavior while applying organization validation. |
| FR-ORG-5 | Quota observations, reset notifications and retry cooldowns retain the organization binding of the observation or launch generation; rebinding invalidates previous usage and late results without attributing an existing running agent to the new organization. |
| FR-ORG-6 | Authentication evidence includes the immutable launch cwd and known project/local authentication settings, with bounded projections before/after verification and before commit; dynamic helpers and unknown managed authentication sources remain unavailable while ordinary project settings and skills stay enabled. |

| Test layer | Required evidence |
|---|---|
| Pure/file | Legacy decode; valid/invalid UUID; absent/matching/mismatching provider identity; root mismatch; oversized/control metadata; independent profile roots; settings merge and no credential/global writes; launch/switch guarded on mismatch. |
| Native components | Organization choice, reuse, status and edit/cancel ownership; asynchronous refresh lifecycle and preserved account selection. |
| Installation | Current signed app/helper identity and unchanged live shell PIDs/layout. Authenticated organization switching is not established by synthetic tests. |

The installed Claude CLI2.1.322 source emits `orgId` and `orgName` in JSON status for claude.ai authentication. The supported preference is documented in [Claude's settings reference](https://code.claude.com/docs/en/settings-reference#forceloginorguuid); CLI login has no organization flag, so Trano must not invent one.

## Remote history input parity

| ID | Acceptance |
|---|---|
| FR-REMOTE-INPUT-1 | Remote wheel/history uses the same bounded native owner/IME/mouse-mode/single-flight guards as local panes. Pin the remote backend PID on first use, separately from the local SSH bridge PID; later operations never adopt a replacement remote process. |
| FR-REMOTE-INPUT-2 | Remote API v1 `panes.history.scroll` accepts exact UUID `id`, positive Int32 `expectedPID` and integer `lines` in[-1000,1000]; `panes.history.cancel` accepts the same identity. Both return `{historyProtocol:1,id,pid,matched,inputReady}`. Validate fresh owned tmux identity and bounded metadata; cancellation verifies post-cancel readiness. Mismatched PID or another mode never authorizes input. |
| FR-REMOTE-INPUT-3 | SSH runs outside the local shared transaction; revalidate immutable local session/reference/host configuration before and after remote work. Old helpers produce a visible update-required error, with no cursor-key fallback that could edit a provider draft. Fake blocked transports must leave unrelated local state operations available. |

## Deferred input safety

| ID | Acceptance |
|---|---|
| FR-QUEUE-5 | Any native/API manual user input invalidates automatic queue readiness before its bytes are delivered. Parser protocol replies do not count as user input. A per-pane/generation revision and trusted submission receipt, rather than Enter or bracketed-paste mode alone, must prove the queued send cannot append to an uncertain manual draft. Unknown or changed input requires review. Preserve clean Done FIFO, per-item reservation, Unicode/IME, bounded work and background persistence. No main-thread file/network work or subprocess per keystroke. |
| FR-QUEUE-6 | Native review/rebind targets the exact live generation/input revision and does not silently clear a user's draft. Shared verified input readiness may authorize Supervisor continuation; missing proof retains `input_review_required`. Fake native/daemon tests cover draft arrival after enqueue and at send commit, parser replies, stale owner/PID, ambiguous submission ordering, and clean Done dispatch. |
| FR-IMAGE-1 | Image upload admission permits at most2 attachments and40MiB in total, with20MiB per item, reserves before enqueue, releases on every outcome and reports a busy retry only to the still-current input owner. |

## Guarded native Supervisor continuation

| ID | Acceptance |
|---|---|
| FR-SUP-6 | Headless CLI/API and the retained native Supervisor expose continuation of already-authorized local managed work through the same `terminalInputReadiness` and `commitTerminalAutomaticInput` lease as the queue. Require exact Supervisor and target launch/birth/provider/conversation/root identity, trusted completed turn with hook origin exited, no unresolved decision, no quota handoff and no user queued FIFO entry. Record reservation before one bounded UTF-8 send; repeat, stale or ambiguous writes cannot replay. |
| FR-SUP-7 | Readiness revision/status changes wake the existing event-driven watch, without input text or proof IDs in watch cursors. Native Go To Session/Review actions retain captured destination and renderer ownership across workspace changes. Review does not clear input or create a ready lease; initial/unknown states require a future captured manual submit and trusted completion. Remote continuation remains unavailable until an authoritative remote input protocol exists. |
