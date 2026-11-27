---
artifact_id: artifact-2026-11-13-trano-workspace-activity
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: closed
version: 1
last_updated: 2026-11-16
---
# Workspace activity dots

| Field | Contract |
|---|---|
| Scope | Session-picker workspace titles show unread activity; entering the workspace clears its captured alerts in both the picker and Activity |
| Source | Existing pane activity, workspace/tab membership and activity read receipts |
| Excluded | New polling, notifications, counters, animations, settings, APIs and session lifecycle changes |
| Acceptance | [WORKSPACE-ACTIVITY-SRS.md](WORKSPACE-ACTIVITY-SRS.md), FR-WSACT-1–3 |
| Verification | Pure/fake/native component units, signed local installation and unchanged jobs/layout/settings; E2E paused |
