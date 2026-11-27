---
artifact_id: artifact-2026-11-13-trano-worktree-cleanup
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implemented
---
# Session-owned worktree cleanup

Trano will automatically clean eligible linked worktrees created by its own terminal tasks after successful completion. Existing unrelated worktrees and branch refs are retained.

| Scope | Behavior |
|---|---|
| Track | A transparent Git wrapper records exact successful creation provenance for a local pane/generation. It does not infer ownership from age or names. |
| Finish | Root completion schedules a guarded background cleanup after a grace period. New activity, user input, decisions, followups or another process using the directory defer cleanup. |
| Preserve | Main/locked/bare, dirty/untracked/ignored, ambiguous identities, in-progress repo operations and unretained detached history stay untouched. |
| Control | Native automatic-cleanup toggle, Activity results with hold reasons, read-only API status and explicit safe retry. |
| Verification | Pure/fake/file/native units; E2E paused. Build/sign/install preserves current sessions and does not remove existing worktrees. |

Git supports nonforce removal of clean linked worktrees; Trano adds provenance, history and active-use checks. [Git worktree documentation](https://git-scm.com/docs/git-worktree).
