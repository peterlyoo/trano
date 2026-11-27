---
artifact_id: artifact-2026-11-13-trano-worktree-cleanup-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-13-trano-worktree-cleanup
state: implemented
---
# Worktree cleanup acceptance

| ID | Priority | Acceptance |
|---|---|---|
| FR-WT-1 | P0 | Record only newly created linked worktrees from successful, attributed local Git creation, with immutable pane/generation/repository/path/admin-dir identity and baseline. Existing/ambiguous worktrees cannot become automatic targets. |
| FR-WT-2 | P0 | Trusted successful root completion schedules a30-second grace; failures/subagents do not. Revalidate current task generation/completion, tools/decisions/followups and input/activity before committing cleanup. |
| FR-WT-3 | P0 | Remove only an exact current linked worktree using git worktree remove without force. Keep all branches/refs. Dirty, untracked, ignored, active-cwd/process, locks, main/bare, changed identity and unretained HEAD block with explicit reason. |
| FR-WT-4 | P0 | Durable private sidecar survives old state writers; serialize captures/cleanup, bound inputs/history/work, treat interrupted removal as review-required rather than blind retry, and perform Git/process scans off UI/runtime shared transactions. |
| FR-WT-5 | P1 | Native automatic-cleanup toggle persists and disables pending deletion; Activity shows removed/held/error and safe retry; API exposes cached metadata/status and guarded control. |
| FR-WT-6 | P0 | Ordinary Git behavior and provider invocation remain compatible. Git shim survives provider PATH normalization without agent-wrapper recursion. Remote ownership is unsupported and explicitly refused. |
| FR-WT-7 | P0 | Pure/fake/native tests pass; no real-worktree removal/provider/PTY E2E; signed install preserves current shell PIDs, exact layout and saved terminal settings. |
