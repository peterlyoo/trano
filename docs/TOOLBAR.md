---
artifact_id: artifact-2026-11-12-trano-toolbar
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implemented
---
# Direct toolbar customization

Right-clicking a toolbar action opens Customize View with checked visibility choices for every action. Tab and blank-header menus retain the same choices for restoring hidden icons.

| Decision | Contract |
|---|---|
| Access | Right-click or Control-click each icon; no intermediate submenu or Settings page |
| Persistence | Private interface-preferences sidecar; default all visible; per-item concurrent merge |
| Scope | Resume, Workspace Actions, Remote Hosts, Decisions, Supervisor, Activity, Reset Tickets, Command Palette |
| Continuity | Hide only the toolbar entry; action, shortcut, open feature and running session remain available |
| Verification | Synthetic preferences and native components; signed local install; E2E remains paused |

## Installed verification

| Evidence | Result |
|---|---|
| Unit checks |22 core+32 native=54 passed;0 failures;8 new visibility/customization cases; `.local/toolbar-customization/final-unit.log` |
| Regression proof |7 initial tests failed before implementation; direct-menu1test/2assertions failed before correction; final selection passed |
| Packaging |26 unit checks passed; SBOM and publication boundary631files verified |
| Signed build | `6a26287f839dca01bf668c33676c2f84b28b4de1285457a6a742eb22f9b50328`; Apple Development; release100.92s |
| Local install | `/Applications/Trano.app`;21 existing shell PIDs and exact layout retained;123 file hashes matched |
| Receipt | `.local/toolbar-customization/installed-receipt.json`; running GUI/helper paths and API identity verified |
| Qualification | E2E paused; physical pointer/IME/OS checks not run |
