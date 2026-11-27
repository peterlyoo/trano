---
artifact_id: artifact-2026-11-11-trano-decisions
parent_id: artifact-2026-11-10-agent-terminal-m2
artifact_type: sdlc-srs
state: implementing
last_updated: 2026-11-11
---

# Native decision inbox

Trano embeds a local decision inbox compatible with the EasyDecision short-lived adapter protocol. Managed agents receive their exact binding and native command through prompt hooks; existing global EasyDecision settings remain untouched. Original requirements U01–U21 remain in scope.

## Requirements

| ID | Contract | Verification |
|---|---|---|
| FR-DECISION-1 | Private newline JSON submit/poll/abandon/gate; native CLI and managed shim; idempotent request IDs; bounded polling; unavailable or older service → native fallback, exit 75 | `DecisionAdapterTests`, `DecisionInboxTests`, `check-decisions.py` |
| FR-DECISION-2 | Exact provider/session/workspace and pane/generation; native producer binding plus kernel socket peer ancestry; pending/unread questions abandoned after exit; pending/unread answer blocks trusted Stop and queued follow-up delivery | `DecisionReviewRegressionTests`, trailing-space workspace regression, real managed-provider restart/exit/gate checks |
| FR-DECISION-3 | Durable choose, optional instruction, Other input (`revise/discuss`), explicit Cancel Question; resolved-answer wins over abandon; immutable encoded `id`; private state and generic activity reasons | Core and native CLI resolution tests, exact Hangul NFD/emoji/newline reply checks |
| FR-DECISION-4 | Pending count centered inside the toolbar speech-bubble outline without a question mark or adjacent duplicate count; same-window overlay; supplied option descriptions and recommendation marker; choice → Send Answer without a review wizard; outside/Escape hides the panel; marked-text safety; terminal input blocked while automatic terminal replies remain enabled | `DecisionInboxViewTests`, real native button clicks and real PTY input/reply regression |
| FR-DECISION-5 | Go to the selected question's exact pending pane/generation without answering or restarting jobs; reopen retained views, reuse existing float ownership, retain unsent answers and protect composition | `DecisionNavigationTests`, `DecisionNavigationUITests`, question-identity regression in `DecisionInboxViewTests` |

### FR-DECISION-5 — Go to Session

The selected question offers a native Go to Session button. It navigates to the exact bound pane/tab/workspace after validating the still-pending request and generation, closes the question overlay without resolving it, and retains unfinished answer choices/text for reopening. Closed workspace/tab views may be reopened without starting a shell; an existing floated pane is focused instead of duplicated. Missing or stale bindings fail visibly without navigating to another session, and marked text or an in-flight decision prevents navigation.

## Trano API v1

| Method | Parameters | Result |
|---|---|---|
| `decisions.list` | optional `paneID` | Entries, including immutable `id`, `question`, `paneID`, `generation`, `createdAt`, `status`, optional `resolution`, `delivered` |
| `decisions.resolve` | `id`, `generation`, `action`; optional `optionID`, `instruction`, `locale` (`en`/`ko`) | Updated entry |
| `decisions.abandon` | `id` | Raw adapter result; a resolved answer is retained |
| `decisions.delete` | `id` | Explicit deletion of a completed question; pending questions refused |

## Agent adapter

| Surface | Contract |
|---|---|
| Transport | User-private `api.sock`; one UTF-8 JSON line per short-lived connection; raw adapter replies without the Trano API envelope; half-closed write supported |
| Submit frame | `type: submit`, `question: {schema_version: "1.0", request_id, thread_id, source: {agent, session_id, workspace}, question, options}` |
| Text | String or `{en, ko}`; 2–4 options with `id`, `label`, `description`; supplied recommendation labels preserved |
| Native context | Private top-level `trano_binding: {pane_id, generation}` automatically supplied by the CLI; `source` retains the upstream schema |
| Legacy client | Submit accepted only from the current provider process or a verified descendant; kernel peer identity unavailable → reject |
| Commands | `trano decision-adapter ask|submit` (JSON stdin); `poll UUID`; `abandon UUID`; `gate --agent claude|codex --session-id ID` |
| Managed environment | `EASYDECISION_SOCKET`, `EASYDECISION_ADAPTER_BIN`, native shim on managed PATH only |
| Existing live agents | Next prompt hook supplies an explicit per-command socket, pane, generation and bundled adapter command; provider restart unnecessary |
| Stop | Pending or resolved-unread → `{decision: "block", reason}`; delivered answer → allow; recording and output computed in one runtime transaction |
| Actions | `choose` + `selected_option_id`; `revise` + `revision_kind: discuss` + instruction; `cancel` without choice/instruction |
| Native fallback | Exit 75 for unavailable/incompatible endpoint; exit 2 for invalid or unsupported operations |

## Storage and limits

| Item | Limit / policy |
|---|---|
| Storage | Separate private `decision-inbox.json` under the owned runtime; shared transaction and atomic replacement; no global app/plugin/credential writes |
| File checks | Owned private regular file; no symlink; 8 MiB maximum, 512 entries |
| Frame | 512 KiB |
| Text per locale | Question 32 KiB; label 2 KiB; description 8 KiB |
| Instruction | 32 KiB, exact UTF-8 |
| Scope | Local managed providers; hosted team discussions, context leasing, understanding quizzes and automatic translation unsupported |

Native widgets and socket/provider fixtures establish local behavior; live authenticated provider qualification and physical OS IME testing remain separate product gates.
