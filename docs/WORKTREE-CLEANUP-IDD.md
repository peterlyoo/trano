---
artifact_id: artifact-2026-11-13-trano-worktree-cleanup-idd
artifact_type: sdlc-idd
parent_id: artifact-2026-11-13-trano-worktree-cleanup-sdd
state: implemented
---
# Worktree cleanup interfaces

| API v1 method | Parameters | Result / guard |
|---|---|---|
| `worktrees.status` | None | `enabled`, `trackingAvailable`, `scope="future-local-session-creations"`, `graceSeconds=30`, `records`; reads metadata only, no Git scan |
| `worktrees.configure` | `enabled: Bool` | Local Unix peer required; updates only `IntegrationsPreferences.automaticallyCleanWorktrees`; returns `enabled` |
| `worktrees.retry` | `id: String` | Local Unix peer; completed `held`/`error` record only; full current policy validation before requeue; no immediate removal |
| `worktrees.keep` | `id: String` | Local Unix peer; drops tracking metadata only; no folder/branch deletion; refuses `removing`/`needsReview` |
| `worktrees.diagnostics` | None | Local Unix peer; read-only `processCensusComplete`, `processCount`, `trackingAvailable`; no process paths/PIDs |

| Internal / durable interface | Contract |
|---|---|
| `tracked-git REAL_GIT ARGS...` | Internal owned shim entry; local caller ancestry and exact before/after capture. Tracking failure falls back to original Git. Capture token in `TRANO_WORKTREE_CAPTURE` prevents recursion. |
| `worktree-cleanup.json` | Private owned bounded sidecar; schema version 1, `captures`, `records`; separate metadata and cleanup operation locks |
| `worktree-task-receipts.json` | Private bounded successful-exit receipts preserve an existing trusted root Stop proof and exact input revision |
| `integrations-settings.json` | Existing Save/Cancel preferences; `automaticallyCleanWorktrees` defaults `true` when absent; no second cleanup preference source |
| Native Activity | Worktrees section, exact hold/review reasons, safe Retry, Keep Worktree, Finder reveal; metadata reads on the existing background model queue |

Requirement mapping: `FR-WT-1`–`FR-WT-7` in [WORKTREE-CLEANUP-SRS.md](WORKTREE-CLEANUP-SRS.md); ownership and limits in [WORKTREE-CLEANUP-SDD.md](WORKTREE-CLEANUP-SDD.md).
