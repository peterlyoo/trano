---
artifact_id: artifact-2026-11-11-trano-follow-ups
parent_id: artifact-2026-11-10-agent-terminal-m2
artifact_type: sdlc-srs
state: implementing
last_updated: 2026-11-11
---

# Queued Input

Trano retains editable follow-up inputs for each pane and delivers one when its local managed coding agent completes a turn. The queue belongs to the background service so closing the app does not suspend delivery. Original requirements U01–U21 remain in scope.

## Requirements

- **FR-QUEUE-1 — Durable editable queue:** Add, list, edit and delete pending inputs per pane through native UI and API. Preserve FIFO order, exact UTF-8 and multiline text. Reject empty, oversized or control input. Existing state files load with an empty queue.
- **FR-QUEUE-2 — Done-only dispatch:** Deliver one input after a trusted root agent reports `done`. `running`, `blocked`, child completion, process exit and stale generation events must not deliver. Confirm the same live foreground agent immediately before sending; never execute queued prose in its shell.
- **FR-QUEUE-3 — Safe background delivery:** The helper owns dispatch independently of GUI lifetime. Reserve a delivery durably before sending, consume each completion once, and retain an explicit review state for an ambiguous interrupted send rather than retrying automatically. A provider restart/recovery requires explicit rebinding before old queued work can run.
- **FR-QUEUE-4 — Compact native interaction:** Queued Input replaces the appearance-profile button in each pane header; no duplicate global toolbar button remains. The pane's own button opens that pane's queue even when another pane has focus. The configurable default `Cmd+Shift+U` toggles the focused pane's queue and appears in menus, the palette and shortcut settings. The overlay shows ordered pending inputs with Add, Edit and Delete. Editing uses Save and Cancel; outside click and Escape dismiss the panel. Marked text prevents toggle/dismissal until committed. Opening the panel does not resize terminal content, restart attach clients or alter normal terminal input. Appearance profiles remain available in the pane context menu.

## Design and interfaces

`RuntimeState` owns queue records; a dedicated `TerminalCore` queue extension validates mutations under the existing runtime transaction. API methods `followups.list`, `followups.add`, `followups.update` and `followups.remove` expose the same contract used by the native app. The background service checks pending work using existing bounded timers. Done eligibility uses validated provider launch identity and root hook activity, not terminal text or transcript inference. Delivery and failures never copy prompt bodies into activity notifications.

The private `continuity.json` sidecar is authoritative for queue records, completion tokens, safe-paste state and Activity read receipts; new runtime snapshots merge it with primary metadata. This preserves new fields when a still-running older supervisor rewrites `state.json`. A new delivery reservation reaches the sidecar before input is sent, and an interrupted reservation requires review instead of automatic retry.

Existing pane output monitors are upgraded without restarting the shell or provider. An already-running provider must emit a fresh safe-paste mode before delivery; otherwise the input remains held with an actionable message. Remote inputs are retained for review and do not automatically send in this revision.

The shared input contract is [FR-QUEUE-5/6](BATCH-COMPLETION-SRS.md): manual user input invalidates readiness before transport, while parser replies preserve it. Native Resume next turn preserves the user's draft and requires a future captured manual submit and trusted completion; it never clears input or creates an immediate send authorization.

## API examples

`followups.list` and `followups.add` take `paneID`; Add also requires `text`. `followups.update` takes input `id` and replacement `text`; `followups.remove` takes input `id`. Records return `id`, `paneID`, exact `text`, `generation`, `status` (`pending`, `sending`, `needsReview`), optional `message`, `createdAt` and `updatedAt`. Editing preserves order, and saving a held input explicitly binds the current managed launch.

## Acceptance evidence

Core tests must cover persistence, editing, deletion, ordering, Unicode/multiline, completion deduplication, non-done states, dead/replaced agents and ambiguous delivery. Native tests must exercise queue actions and overlay containment without changing terminal bounds. The full suite, signed installation and preservation of existing shell PIDs/layout are required before completion.
