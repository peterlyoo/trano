---
artifact_id: artifact-2026-11-13-trano-pessimistic-twin-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-13-trano-pessimistic-twin
state: implemented
---
# Pessimistic twin acceptance

| ID | Priority | Acceptance |
|---|---|---|
| FR-TWIN-1 | P0 | Pane header, Command Palette and API enable the same workflow with code/security/general mode; capture exact live local source pane, generation, provider, account/configuration root and verified conversation UUID; no account/provider fallback or twin-of-twin activation. |
| FR-TWIN-2 | P0 | A trusted source root done boundary creates a snapshot commit containing current tracked and all nonignored untracked files, binary/Unicode/symlink/deletion changes included, without changing source working files, real index or HEAD; fail visibly on partial/unstable/unsupported input; create an exact owned branch/worktree from that commit. |
| FR-TWIN-3 | P0 | Code/general use `claude --resume ID --fork-session` or `codex fork ID PROMPT` in the twin worktree; Codex uses workspace-write with explicit cwd; twin launch starts with no inherited conversation ID and verifies its new ID differs. Security starts a fresh same-provider session given snapshot diff only, without source conversation history. |
| FR-TWIN-4 | P0 | The twin receives a mode-specific pessimistic Role, Task, and Objective requiring concrete evidence and direct fixes in the twin branch. Project writes are confined to the twin worktree by combining restricted provider tools, a strict native inner shell sandbox, and scoped IPC rather than relying on `acceptEdits` or prompt text alone; an outer whole-provider sandbox was rejected and is not the current architecture. The reviewer has zero write access to shared Git metadata, commits occur only through the trusted bound native bridge, and narrow provider private bookkeeping stays outside the checkout. Reviewer content, commits, and inherited context never constitute human consent; `FR-SUP-4` native human decisions remain mandatory and no bypass flags are permitted. |
| FR-TWIN-5 | P0 | Native report submission validates exact twin run/round/pane/generation/provider ancestry and new conversation, trusted root completion, snapshot ancestry, actual committed tip and changed_files; preserve AgentOutput snake-case fields including status, rationale and changed_files; no-op uses no_further_improvement; invalid output terminates visibly without merge. |
| FR-TWIN-6 | P0 | Existing Decision inbox renders merge/feedback-only/discard choices. Workflow association survives twin exit and old state writers, does not block the source Stop needed for merge, and cannot be resolved/polled/abandoned by an agent through generic Decision API. Only native human choice creates consent bound to run/round/source/snapshot/twin tip; consumption is idempotent. |
| FR-TWIN-7 | P0 | Merge choice waits for a new trusted source completion after consent, exact source/branch/baseline and current input/tools/queue/decision guards. If original dirty bytes and index exactly match the approved snapshot, durably checkpoint that snapshot before normal nonforce merge. Divergence/uncertain mutation requires review; conflicts remain intact and are not automatically resolved. Feedback-only never merges; discard does not forward an applied-result claim. |
| FR-TWIN-8 | P0 | Forward applied changes/findings through existing Queued Input insertion and delivery with stable idempotency identity; do not backdate inputs or weaken done/foreground/paste/input guards. Explicit source response can continue rebuttal rounds; default round_cap=3 and noop_cap=2 bound repetition. Exact exit names: agent_agreement, noop_cap, round_cap, user_interrupt, agent_unavailable, invalid_agent_output. |
| FR-TWIN-9 | P0 | Durable private bounded sidecar and owned resource reservations survive helper restart/old state writers; Git, launch, merge, queue and cleanup intents cannot blindly repeat after interruption. Active twin paths are excluded from generic worktree cleanup. On finish remove only the exact owned safe pane/worktree/branch; preserve dirty, active, conflicted or uncertain resources with diagnostics. |
| FR-TWIN-10 | P0 | Verify required CLI options, Claude confinement and untracked snapshot before implementation; TDD pure/fake/file/native units and isolated Git-plumbing fixture only; real provider/PTY/physical E2E remains paused. Build, sign and install the complete slice with existing shell PIDs/layout/settings preserved. |

| Interface | Canonical behavior |
|---|---|
| Mode | `code_review`, `security_review`, `general_review` |
| Twin APIs | Global methods are `twins.status`, `twins.enable`, `twins.stop`, and `twins.respond`; reviewer-only scoped methods are `twins.hook`, `twins.diff`, `twins.commit`, and `twins.report`; merge consent remains native human-only with no `twins.resolve` endpoint. |
| Decision | Existing renderer and explicit answer UI, protected workflow association in twin sidecar |
| Queue | Existing `followups.add` semantics with durable idempotent insertion |
| Report | AgentOutput-compatible JSON; untrusted context, never authorization |
| Scope | macOS local managed Claude/Codex; unsupported prerequisites fail visibly; no live job creation during verification |
