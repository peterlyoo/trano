---
artifact_id: artifact-2026-11-13-trano-batch-completion
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implemented
---
# Accumulated request completion

Every accepted Trano request remains in scope until its actual entrypoint and consumer are accounted for. A completed recent slice or an empty local pending list does not establish completion of the accumulated requests.

| Workstream | Contract |
|---|---|
| Request inventory | Original U01–U21 and later corrections map to owning implementation, allowed verification, installation and explicit remaining limits. The withdrawn AgentBoost count request stays excluded. |
| Existing behavior repairs | Correct concrete source omissions across navigation, terminal/settings and agent workflows; preserve existing live PIDs, layout and preferences. |
| Organization-aware Claude profiles | Select, show and verify an organization independently for each managed profile, including the same Claude account in multiple organizations. Never infer organization from an email or alter global credentials. |
| Verification | Pure/fake/native-component units; E2E remains paused. Build/sign/install actual app and verify backend/session continuity. |

Organization selection uses Claude's documented per-profile login preference; non-managed settings preselect rather than enforce an organization. Trano must verify the provider-reported identity before treating a selected organization as matched. [Claude settings reference](https://code.claude.com/docs/en/settings-reference#forceloginorguuid).

## Acceptance

| Requirement | Completion rule |
|---|---|
| FR-BATCH-1 | Every accepted request has an evidence-backed disposition; missing implementation is not relabeled as only a qualification limit. |
| FR-BATCH-2 | Concrete omissions are implemented with combined allowed unit regressions and a signed installed receipt. |
| FR-ORG-1–4 | [Organization contract](BATCH-COMPLETION-SRS.md) passes synthetic identity/config/native controls and preserves existing profile roots and credentials. |
