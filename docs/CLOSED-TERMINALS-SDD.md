---
artifact_id: artifact-2026-11-16-trano-closed-terminals-sdd
artifact_type: sdlc-sdd
parent_id: artifact-2026-11-16-trano-closed-terminals-srs
state: reflected
version: 1
authors: [codex]
last_updated: 2026-11-16
traceability_to: [artifact-2026-11-16-trano-closed-terminals-srs]
---

# Software Design Description: Closed Terminals

> **Summary**: Details the two-phase capture-and-terminate mechanism, sidecar persistence, shell history journaling, and failure recovery paths.

## Overall Flow: Two-Phase Capture and Terminate

```
[Explicit Close Request]
          |
          v
[1. Recheck Target Identity]
          |
          v
[2. Capture All Target Panes to Sidecar]
   (Abort on failure -> Panes unchanged)
          |
          v
[3. Persist 'closing' State in Sidecar]
          |
          v
[4. Terminate Local/Remote Processes]
          |
          v
[5. Commit LIFO Entry (Max 20)]
```

The coordinator captures every targeted pane before sending any termination signal, ensuring pre-stop failures leave the workspace untouched.

## Mechanism: Sidecar Storage, Shell Hooks, and Restore Pipeline
- **Private Close-State Sidecar (FR-CLOSE-2, FR-CLOSE-7)**: Because `Runtime.swift` `terminate` deletes metadata and older live supervisors overwrite `RuntimeContinuity.swift`, close archives are written to a separate local-only private directory using `0600`/`0700` permissions and `O_NOFOLLOW`. `Recovery.swift` reads this sidecar to filter out intentionally closed panes from automatic crash restoration.
- **Shell Integration & Launch Selection (FR-CLOSE-3)**: `ShellIntegration.swift` is updated so supported shells journal commands prior to execution/prompt. For older live shells without hooks or where a foreground agent blocks safe export, capture records only available on-disk history and records history provenance metadata as `persistedFallback` rather than claiming exact in-memory capture. `TerminalLaunchSelection.swift` reads the archived shell kind instead of hardcoding `zsh`, keeps original launch arguments immutable against exit hooks, strips arbitrary startup commands, replays ANSI-sanitized screen buffers (<=10,000 lines / 4 MiB), and loads history via history-file import.
- **Topology & Provider Resume (FR-CLOSE-3, FR-CLOSE-4)**: `Sources/TerminalCore/Workspace.swift` pops the LIFO stack (bounded to 20). If sibling panes in a closed split were moved elsewhere, restore recreates only the closed slots without duplicating or stealing live moved panes. For Claude/Codex panes, restore verifies the old process has exited, allocates a new generation ID, and resumes the saved conversation ID under the recorded provider/account/org context.
- **Remote Helper Extension (FR-CLOSE-6)**: `remote/main.go` adds a snapshot-and-stop command advertised via capability handshake. Local coordinators release the workspace state lock before performing SSH RPCs.

## Failure Handling: Pre-Stop Abort, Partial Close, and Degradation
- **Pre-Stop Capture Failure**: If identity validation or snapshot writing fails before stopping begins, no process is signaled; any published close markers are restored and acknowledged remote preparations are cancelled.
- **Partial Stop / Ambiguous Remote Failure**: Once `closing` is persisted, if stopping the *n*th pane fails or SSH times out ambiguously, already-captured archives remain valid, failed panes stay marked for retry/reconciliation, and retry operations are idempotent.
- **Provider or Account Unavailable**: If the saved provider, account, or org context has changed or is unreachable on restore, Trano boots the fresh shell in the saved `cwd`, writes an actionable recovery banner/record, and suppresses automatic prompt resubmission.

### Retry and concurrency guarantees

- `ClosedTerminalStore.operation` holds a separate nonblocking private `flock` across explicit close/reopen, while `Runtime.update` blocks moving/removing owned closing/restoring panes. Shared runtime state transactions do not span remote SSH RPCs or descendant exit waits. Explicit floating-pane `CmdW` stops/saves; native floating red-close/Return Pane only returns the view (`Sources/TerminalCore/ClosedTerminalStore.swift`, `ClosedTerminalRuntime.swift`, `App.swift`).
- Preparation captures every target before any stop, and an unknown original shell cancels close instead of silently substituting `zsh`. Pre-stop failures restore previous close markers and cancel acknowledged remote prepared snapshots. Once stopping begins, original archive/process witnesses stay immutable across retries, and close failures collect reconciliation diagnostics alongside the original failure. A successful remote stop followed by local validation failure is reconciled through `close.status`, retiring the stopped original SSH bridge while keeping saved remote state available; uncertain status remains pending without false success (`ClosedTerminalRuntime.swift`, `ClosedRemoteTerminal.swift`).
- Partial restoration retains the undo entry and already-created shell, `Workspace.restoreTab` deduplicates existing/moved siblings, and the reopened phase plus `TRANO_REOPEN_ARCHIVE` marker avoid duplicate shell starts when retrying a save interruption (`ClosedTerminalRestore.swift`, `Workspace.swift`). Real provider/SSH/PTY/physical GUI qualification is intentionally unrun under user E2E pause; tests use fake transports and inert native components.

Native history encoding amendment (2026-11-16):zsh/bash archives preserve nonUTF8 native bytes as Data;UTF8 is required only for fish. Ownership,no-follow,NUL,size/entry bounds and import-as-data safeguards remain. Seven encoding regressions and21 lifecycle tests pass;actual user history was read for byte metadata only and was not modified.
