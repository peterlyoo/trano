---
artifact_id: artifact-2026-11-11-trano-tab-activity
parent_id: artifact-2026-11-10-agent-terminal-m3
artifact_type: sdlc-srs
state: implemented
last_updated: 2026-11-11
traceability_to: [U07, U08]
---

# Live tab activity

Hovering a tab shows its panes, root agents, and reported subagents without changing selection or keyboard focus.

- FR-HOVER-1: Show root and child running, blocked, done, error, idle, or unknown status for every pane in the hovered tab; retain provider identity and source timestamp.
- FR-HOVER-2: Refresh an open hover from existing background state updates; close on pointer exit or window deactivation without starting polling or network requests.
- FR-HOVER-3: Accept child metadata only through structured provider hooks or OSC child records; isolate root identity and supervision, reject stale generations and unrelated probes, and bound storage to 64 children per pane.
- FR-HOVER-4: Decode old snapshots without child metadata, transport equivalent metadata from Linux helpers, and clear obsolete child state when a new root launch starts.

The additive `TerminalSession.agentTasks` array contains `id`, optional `parentID`, `name`, `agent`, `activity`, and optional `generation`; absent metadata means no reported children, not proof that no subagents exist.

## Verification and limits

| Requirement | Verification |
|---|---|
| FR-HOVER-1 | `AgentTaskTests`, `TabActivityHoverTests`, `experiments/check-tab-activity.py` |
| FR-HOVER-2 | Seven native hover tests; `.local/tab-hover-card.png` inspected |
| FR-HOVER-3 | Local hook/OSC isolation tests, real tmux transport, Linux helper tests |
| FR-HOVER-4 | Legacy decoding, generation reset, remote import timestamp preservation |

| Surface | Observed contract |
|---|---|
| Local updates | Existing background file watcher with 100 ms debounce |
| Remote updates | Existing background SSH refresh, 15 seconds; no hover polling |
| Claude children | Lifecycle and identified operational hooks |
| Codex children | Lifecycle hooks report running/done; detailed states require identified OSC records |
| Native verification | Real NSPanel and NSHostingView with deterministic owner-key test fixture; physical pointer interaction unverified |
| Provider qualification | Fake providers over real PTYs; authenticated live subagent execution unverified; Codex hook trust remains provider-controlled |
| Final remote parser fix | Darwin Go race tests passed; Linux cross-compilation passed; Linux rerun unavailable because the named fixture container no longer exists |

Provider fields follow [Claude hooks](https://code.claude.com/docs/en/hooks) and [Codex hooks](https://learn.chatgpt.com/docs/hooks); hook payload prompts and transcript paths are discarded.
