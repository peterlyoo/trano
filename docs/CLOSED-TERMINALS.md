---
artifact_id: artifact-2026-11-16-trano-closed-terminals
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: reflected
version: 1
authors: [codex]
last_updated: 2026-11-16
traceability_to: [artifact-2026-11-10-agent-terminal-prd]
---

# Explicit Terminal Close State Capture and Process Termination

> **Summary**: Explicit pane and tab closures (`Cmd+W`, tab/pane context/X, close others) will capture topology, working directory, screen/scrollback, shell kind, command history, and AI conversation context before terminating processes. `Cmd+Shift+T` will restore a fresh shell and resume exact Claude or Codex conversations without rerunning live jobs.

## Goal: Replace Keep-Running Close with Capture-Then-Terminate
Explicit close currently leaves processes running or erases runtime metadata. This milestone supersedes keep-running pane/tab close while preserving keep-running behavior for window/app closure, workspace hiding, and drag/move operations.

## Acceptance Criteria: Safe Capture, Clean Stop, Exact Restore
1. Explicit close archives all target panes in bounded private storage before stopping any process, then terminates the target processes.
2. Closed panes do not auto-restore on crash/relaunch, while surviving and moved panes remain intact.
3. `Cmd+Shift+T` restores LIFO up to 20 closed items into a new same-kind shell, `cwd`, sanitized screen/scrollback, imported history, and resumed Claude/Codex conversation with saved provider/account/org context.
4. No external package dependencies are added, and existing user scripts, preferences, and live terminal PIDs remain untouched during build, install, and verification.

## Architecture Dependencies: Core, Runtime, Shell, and Remote Helper
- `Sources/TerminalCore/Workspace.swift`: Extend the existing LIFO bounded-20 `closedTabs` model while preserving surviving and moved panes.
- `Runtime.swift` and `remote/main.go`: Bypass destructive `terminate` paths that erase metadata/sessions; add non-erasing close and remote helper capability gates.
- `Recovery.swift` and `RuntimeContinuity.swift`: Exclude intentional closes from automatic crash restore and isolate close-state in a private sidecar so older live supervisors cannot overwrite it.
- `ShellIntegration.swift` and `TerminalLaunchSelection.swift`: Add pre-execution/prompt history journaling and remove hardcoded `zsh` restore.

## Verification Strategy: Unit and Inert Fixture Testing Only
Verification is strictly limited to pure unit tests, fake mux/transport tests, and inert native fixtures. Live shell, provider, PTY, SSH, and GUI E2E tests are paused by user directive, and no live user terminal may be killed during testing.

## Risks and Constraints: Unhooked Shells and Legacy Supervisors
- Live shells without updated hooks cannot safely export unsaved in-memory history while an agent owns the foreground; Trano must fall back to available on-disk history and record history provenance metadata truthfully without claiming exact memory capture.
- Older live supervisors rewrite `RuntimeContinuity.swift` state, requiring an independent sidecar file.
- Real provider, remote helper, and live shell integration qualification remains unrun in this milestone.

## Installed Verification — 2026-11-16

| Evidence | Result |
| --- | --- |
| Focused Swift / Go gates | 116 Swift units; 44 fake/pure Go race tests; no failures |
| Source binding | 50 closed-feature source/test hashes unchanged after unit verification; later source changes limited to separately tested IME repair |
| Independent reflection | Claude rival accepted; `.local/closed-terminal-state/{final-review,unit-receipt}.json` and `.findings/final.md` |
| Signed local installation | Apple Development; 8a3bf2453d1e2a3144d7a08dd81dfc766af39e890180b513afa04c327e2f0909; 129 bundle hashes; GUI/helper/API identity verified |
| Continuity | 63 live shell PIDs, layout/settings and 4 preference sidecars preserved; `.local/closed-terminal-state/installed-receipt.json` |
| Qualification limits | On-disk fallback for legacy unhooked shell history; remote helpers packaged, not deployed; real PTY/provider/SSH/GUI E2E paused |
