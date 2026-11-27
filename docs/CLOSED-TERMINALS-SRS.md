---
artifact_id: artifact-2026-11-16-trano-closed-terminals-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-16-trano-closed-terminals
state: reflected
version: 1
authors: [codex]
last_updated: 2026-11-16
traceability_to: [artifact-2026-11-16-trano-closed-terminals]
---

# Software Requirements Specification: Closed Terminals

> **Summary**: Defines functional, nonfunctional, and interface requirements for capturing terminal state prior to process termination and restoring it via `Cmd+Shift+T`.

## Scope: Explicit Pane/Tab Close and LIFO Restore
Applies only to explicit user pane/tab close actions (`Cmd+W`, context menu, close button `X`, close others) and `Cmd+Shift+T` restore. Window/app closure, workspace hiding, and pane/tab drag/move retain keep-running semantics.

## Functional Requirements

| ID | Priority | Title | Requirement |
| :--- | :--- | :--- | :--- |
| FR-CLOSE-1 | P0 | Capture-Before-Stop | Capture all target panes into private bounded archives with exact identity recheck before stopping any process; aborting before stop leaves all panes unchanged. |
| FR-CLOSE-2 | P0 | Process Termination & Exclusion | Persist `closing` state before kill, terminate target processes, exclude intentional closes from crash/auto-restore, and support recoverable partial close. |
| FR-CLOSE-3 | P0 | Shell, History & Topology Restore | Restore LIFO into a new same-kind shell and `cwd` without stealing moved siblings or relaunching live jobs; replay display and import history with recorded history provenance metadata without executing archived commands. |
| FR-CLOSE-4 | P0 | Provider Conversation Resume | Resume exact Claude/Codex conversation with saved provider/account/org context under a fresh generation after guarding for old-process exit; if unavailable, open a fresh shell with an actionable recovery record and no duplicate submissions. |
| FR-CLOSE-5 | P0 | Shared Routes & Truthful Labels | Route native UI, API, and CLI through shared close/restore handlers with captured target/input guards and UI labels that truthfully describe close behavior. |
| FR-CLOSE-6 | P0 | Remote Snapshot & Capability Gate | Use remote helper-owned snapshots behind a capability guard, execute SSH outside the local state lock, and reconcile ambiguous responses safely. |
| FR-CLOSE-7 | P0 | Private Sidecar & Legacy Survival | Store snapshots in `O_NOFOLLOW` private user-owned bounded files that survive rewrites of `RuntimeContinuity.swift` by older live supervisors. |

## Nonfunctional Requirements: Security, Bounds, and Safety
- **Bounds**: Screen/scrollback archives are capped at 10,000 lines and 4 MiB per pane; `closedTabs` remains bounded to 20 LIFO entries; history archives are bounded.
- **Sanitization**: Display replay strips unsafe terminal control sequences, retaining only text and colors. History is imported as data, never passed to `eval` or `source`, and arbitrary startup commands are never rerun as shell or history.
- **Immutability & Authority**: Original launch metadata remains immutable despite exit hooks. Archived terminal state introduces no production, destructive, or shared action authority.
- **Environment Preservation**: Zero new package dependencies. Signed build and installation must preserve all existing user scripts, preferences, layout, and live shell PIDs.

## Interfaces: Native UI, CLI, API, and Remote Protocol
All entry points (`Cmd+W`, `Cmd+Shift+T`, tab/pane context/X, close others, CLI, and local API) invoke a unified workspace coordinator. Remote sessions negotiate a snapshot-before-terminate capability with `remote/main.go` before issuing termination.
