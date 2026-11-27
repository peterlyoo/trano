---
artifact_id: artifact-2026-11-13-trano-worktree-cleanup-sdd
artifact_type: sdlc-sdd
parent_id: artifact-2026-11-13-trano-worktree-cleanup-srs
state: implemented
---

# Worktree cleanup design

This contract specifies requirement ownership, state transitions, and operational limits for tracked Git worktree cleanup.

## Requirement ownership

| Requirement | Owning modules and interfaces | Contracted behavior |
| --- | --- | --- |
| FR-WT-1 | `GitTrackingShell.swift`, `WorktreeGitParser.swift`, `WorktreeCleanup.swift` | Owned Git shim at `root/git-bin/git` and compatibility `root/bin/git`, `root/shell/bin/git`. Tracks before/after successful supported `worktree add` only. Preserves argv, inherited IO/environment/status; nested captures and unknown forms bypass tracking. Records exact pane/generation/backend birth and repository/path/admin directory identities. Existing and concurrent ambiguous targets cannot be automatically removed. |
| FR-WT-2 | `Recovery.swift`, `WorktreeCleanupRuntimeIntegration.swift` | Requires validated root Stop and 30-second grace; no subagent/failure/process-exit-only completion. Checks exact completion/turn, idle status, input readiness revision, tools, pending decisions, queued input, account switch, and live sessions. A code-zero provider exit may retain an already trusted Stop proof; never invent completion from exit. For successful provider exit, exact old managed input binding is read without rewriting ledger; any post-exit shell input or replacement invalidates it. |
| FR-WT-3 | `WorktreeGitInspector.swift`, `WorktreeGitNative.swift` | Uses fixed `/usr/bin/git`, restricted inspection environment, and bounded command/filesystem/process census. A PID missing normal BSD identity may be excluded only if a successful full-size `sysctl` snapshot verifies exact PID, current real/effective UID, `SZOMB` and valid nonzero birth time; keeps excluded PIDs in both census membership samples and rechecks every excluded PID's exact birth/ownership/zombie evidence after final membership comparison, while live/unknown/permission/short/invalid/reused PID evidence makes the census incomplete and children remain ordinary census entries. Keeps main/bare/locked/prunable/dirty/untracked/ignored, sparse/hidden-index, local clean/process filters, in-progress repository operations, unretained HEAD, changed identities, or uncertain active process use. Retains branch refs. Executes nonforce `git worktree remove -- PATH` only. Final context and nonforce mutation run together inside the existing shared runtime transaction, serializing native/API/automatic input admission. All Git/filesystem/process inspection stays outside. The final mutation uses a five-second command timeout and may briefly delay other runtime actions; no user input is discarded. |
| FR-WT-4 | `WorktreeCleanupStore.swift`, `APIService` | Persists private separate `worktree-cleanup.json` with short metadata lease and cleanup-pass lease. Runs Git/process scans outside shared runtime transactions and app main thread. `APIService` owns the background worker on a five-second cadence; stop disables final context. |
| FR-WT-5 | `IntegrationsPreferences.automaticallyCleanWorktrees`, Activity Worktrees, `worktrees.*` | Defaults `true` for future tracked creations under existing Save/Cancel settings. Exposes `pending`/`held`/`removing`/`removed`/`needsReview`/`error` with reasons, Finder for existing target, safe Retry for completed `held`/`error` only, and Keep to remove tracking metadata only (disabled during `removing` or review-required outcome). Read-only `worktrees.status` returns `enabled`/`trackingAvailable`/`scope`/`graceSeconds`/`records`. Local Unix peer required for `worktrees.configure(enabled Bool)` (updates `integrations-settings.json` only), `worktrees.retry(id)`, `worktrees.keep(id)`, and `worktrees.diagnostics` (`processCensusComplete`/`processCount`/`trackingAvailable`, no process paths/PIDs). |
| FR-WT-6 | Shell and Git fallback boundaries | Plain shell creations may be tracked, but ordinary shell exit never establishes managed task completion. Remote cleanup is unsupported. Absolute Git or unsupported options bypass tracking. Missing helper falls back to original Git. |
| FR-WT-7 | Test and installation constraints | E2E is paused by user; pure/fake/filesystem/native-component tests only, with no actual worktree removal as a test. Pure tests assert the literal zombie-census guards and differing birth identities; this refinement follows installed read-only kernel diagnostics and no actual worktree operation was run. Signed installation must retain live shell PIDs, layout, and saved settings. |

## State flow

| State / event | Transition | Rule |
| --- | --- | --- |
| `tracked` | `-> pending` | Becomes `pending` immediately on trusted completion and `eligibleAt` is `completedAt`+30 seconds. |
| `pending` | `-> removing -> removed` | The 30-second grace is checked before `removing`, not before `pending`. Passes safety checks, then runs final context and nonforce `git worktree remove -- PATH` together inside the shared runtime transaction. |
| Safety check hold | `-> held` | Triggered when inspection keeps the worktree. |
| Interrupted / uncertain removal or concurrent creation | `-> needsReview` | No automatic retry; concurrent creation is review-required. |
| Explicit safe Retry | `held` / `error -> pending` | Requeues completed `held`/`error` records only after policy validation. |
| Keep | Removes metadata | Removes tracking metadata only; disabled during `removing` or review-required outcome. |

## Limits

| Scope | Constraint |
| --- | --- |
| Store quotas | 1 MiB sidecar, 32 captures, 128 active records, 256 total, 128 removed history, 1800-second capture TTL, two targets per pass, five-second worker cadence, 30-second grace, five-second final mutation command timeout. |
| Filesystem races | External filesystem writes after final checks cannot be atomically excluded by application checks; repeated inspections and nonforce removal are conservative but do not eliminate ignored-file races. |
| Unqualified surfaces | Custom signal-handler/group signal parity, physical terminal/GUI behavior, real provider/root hooks, real worktree operations, and remote cleanup are not qualified by fake units. |
| Branch retention | All created branches stay, including branches not merged into `main`. |
