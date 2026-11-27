---
artifact_id: artifact-2026-11-13-trano-pessimistic-twin
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implemented
---
# Pessimistic twin

Fork a live coding conversation into an isolated pessimistic reviewer that fixes its findings, then return the result through human-approved merge or feedback. Deliver review, correction, merge, forwarding and cleanup together.

## Use a managed local conversation

In a build that includes this feature, open a managed local Claude or Codex pane, click the pane **Twin** button or open the Command Palette (`Pessimistic Twin`), and choose `Code Review`, `Security Review`, or `General Review`. The review starts on the source conversation's next completed turn.

When a round finishes, use the Decision Inbox actions `Merge`, `Feedback Only`, or `Discard`. **Merge always waits for a new original source completion after your choice**, checks the baseline and index guards, and holds if new source changes or conflicts appear. Choose `Stop Twin` to end the workflow with owned safe cleanup: ignored outputs stay in `artifacts` quarantine, and unsafe, busy, or conflicted resources remain for inspection.

| Step | Contract |
|---|---|
| Enable | Pane header, Command Palette or API; code, security or general review; retain exact source provider/account/conversation/generation |
| Snapshot | Trusted root done boundary; include current tracked and nonignored untracked bytes in a private-index commit; preserve source files, real index and HEAD |
| Review | Always create an owned branch/worktree; same-provider exact fork with a new conversation ID; security review starts fresh with snapshot diff only |
| Return | Validate `AgentOutput`-compatible status/rationale/changed_files and actual committed tip; protected native Decision inbox offers merge, feedback-only or discard |
| Merge | Explicit human choice only; next fresh source done boundary; exact source baseline, input and branch revalidation; preserve conflicts for the person |
| Forward | Existing Queued Input and `followups.add`; stable insertion identity, unchanged done/input gates; bounded rebuttal rounds |
| Finish | Exact named termination reason; remove only owned safe twin pane/worktree/branch; preserve uncertain or conflicted artifacts |

Specification: [PESSIMISTIC-TWIN-SRS.md](PESSIMISTIC-TWIN-SRS.md); Design: [PESSIMISTIC-TWIN-DESIGN.md](PESSIMISTIC-TWIN-DESIGN.md); API: [PESSIMISTIC-TWIN-API.md](PESSIMISTIC-TWIN-API.md); Unit verification: [PESSIMISTIC-TWIN-TESTS.md](PESSIMISTIC-TWIN-TESTS.md). These documents preserve compatibility provenance to the `ipagent` persona and report conventions without introducing any private dependency or claiming milestone completion.
