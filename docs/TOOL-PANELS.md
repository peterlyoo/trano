---
artifact_id: artifact-2026-11-13-trano-tool-panels
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: closed
version: 1
last_updated: 2026-11-13
---
# Shared tool panel presentation

Customize View tools use one theme authority and shared panel design.

| Acceptance | Contract |
|---|---|
| AC1 | Light/dark/tinted current interface colors reach every utility/overlay/native tool. |
| AC2 | Header40, title13, body12, inset16, radius8, close24 use shared components/metrics. |
| AC3 | Existing guarded dismissal, draft/IME/save, focus and live-session identity survive. |
| Children | [SRS](TOOL-PANELS-SRS.md), [design](TOOL-PANELS-DESIGN.md), native component tests |
| Verification | Native mounted components, deterministic colors/geometry, inspected offscreen captures, unit regression, signed local install; E2E paused. |
