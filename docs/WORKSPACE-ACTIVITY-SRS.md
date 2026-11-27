---
artifact_id: artifact-2026-11-13-trano-workspace-activity-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-13-trano-workspace-activity
state: closed
version: 1
last_updated: 2026-11-16
---
# Workspace activity dot requirements

| ID | Priority | Acceptance |
|---|---|---|
| FR-WSACT-1 | P0 | The current `store.sessions` projection is authoritative; cached `state.sessions` can differ. A displayed workspace row has a small noninteractive dot immediately after its title when any contained live pane has unread done, blocked or error activity; running status alone, already-read events, unrelated panes and missing/dead panes do not qualify |
| FR-WSACT-2 | P0 | Entering or explicitly reselecting a workspace acknowledges the captured unread events in all of its tabs and split panes, using the durable receipts shared with Activity and Dock counts. Newer and unrelated workspace events remain unread. Opening/filtering the picker and passive same-workspace refresh do not acknowledge events; no polling or job lifecycle changes |
| FR-WSACT-3 | P0 | Preserve row search/selection, compact title truncation, native context actions, shortcuts, dragging and accessible title; the dot has an exact native identifier for component verification and no interactive hit target |

| Evidence | Gate |
|---|---|
| Unit | Workspace membership/state/read-receipt cases plus mounted native row transitions |
| Installed | Rebuild, Apple Development signature, local bundle/running identity, unchanged shell PIDs/layout/settings |
| Limits | Physical pointer/provider/PTY/SSH E2E remains paused |
