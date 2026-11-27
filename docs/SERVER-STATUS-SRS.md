---
artifact_id: artifact-2026-11-13-trano-server-status-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-13-trano-server-status
state: implemented
---
# Server status acceptance

| ID | Priority | Acceptance |
|---|---|---|
| FR-SERVER-1 | P0 | A retained native NSStatusItem belongs to the existing LSUIElement helper; it is registered before runtime initialization and shows startup errors instead of immediately exiting. |
| FR-SERVER-2 | P0 | Only a successful bounded server.info probe matching API version, PID, build and background kind enters Running. Failure, stale responses and old restart generations cannot claim readiness. |
| FR-SERVER-3 | P0 | Menus render cached state and provide Open Trano, retry, in-process API restart and Quit Server; restart never terminates tmux/provider jobs. Signed update handoff still exits the old helper. When API initialization fails, Quit Server releases the helper lease so an updated build can start. |
| FR-SERVER-4 | P1 | Cheap cached diagnostics are available through server.info; normal labels avoid socket paths and raw internal identifiers. Error details can be copied. No heartbeat mutates the runtime root. |
| FR-SERVER-5 | P0 | Fake transport/state/native menu unit tests cover success, failure, identity mismatch, restart ownership and action targets; actual signed install preserves live PIDs, layout and settings. E2E remains paused. |
