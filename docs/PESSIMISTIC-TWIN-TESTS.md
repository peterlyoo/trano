---
artifact_id: artifact-2026-11-13-trano-pessimistic-twin-tests
artifact_type: test-suite
parent_id: artifact-2026-11-13-trano-pessimistic-twin-srs
state: implemented
---
# TDD strategy

| Requirements | Unit / component acceptance |
|---|---|
| FR-TWIN-1,3 | All native/API access paths, exact provider/account/conversation and new fork identity, security fresh context, unavailable provider and invalid modes |
| FR-TWIN-2 | Isolated Git-plumbing proof of complete untracked/binary/Unicode/deletion/symlink snapshot with original HEAD/index/files unchanged; injected instability/filter/operation cases |
| FR-TWIN-4 | `PessimisticTwinSandboxTests`, `PessimisticTwinPrivateReadTests`, `PessimisticTwinBridgeCLITests`, `PessimisticTwinAliasAdmissionTests`, `PessimisticTwinAuthenticationTests`, `PessimisticTwinProfileProcessUseTests` |
| FR-TWIN-5 | `PessimisticTwinModelTests`, `PessimisticTwinRuntimeGitWorkTests`, `PessimisticTwinHookAdmissionTests` |
| FR-TWIN-6,7 | Protected workflow card survives exit, generic agent resolve/poll refused, native explicit consent required, fresh source done/input/baseline and conflict/uncertain mutation preservation |
| FR-TWIN-8 | `PessimisticTwinCoordinatorTests`, `PessimisticTwinStoreTests`, `PessimisticTwinReservationTests`, `PessimisticTwinArtifactTests` |
| FR-TWIN-9 | `PessimisticTwinGitPathTests`, `PessimisticTwinStoreTests`, `PessimisticTwinReservationTests`, `PessimisticTwinRetirementTests`, `PessimisticTwinProfileCleanupTests`, `PessimisticTwinArtifactFileTests`, `PessimisticTwinWorkerIsolationTests` |
| FR-TWIN-10 | `PessimisticTwinGitPlumbingTests`, `PessimisticTwinRuntimeGateTests`, `PessimisticTwinRunCLITests`, `PessimisticTwinProfileProcessUseTests` |

`.local/pessimistic-twin/snapshot-preflight.json` is a development proof artifact only and is not a runtime qualification gate. The latest aggregate run recorded in `.local/pessimistic-twin/unit-receipt.json` (`passed`, from the same `final-unit-green.log` invocation) passed 1364 product unit tests (`TranoCLITests.xctest` 38/0, `TerminalUITests.xctest` 474/0, `TerminalCoreTests.xctest` 826/0, Swift Testing 26/0) with 0 failures, including 299 Pessimistic Twin tests as a subset, while `.local/pessimistic-twin/packaging-unit.log` separately passed 45/0 packaging tests.

Unit fixtures exercise isolated temporary files and Git plumbing rather than user repositories.

| Recorded gate | Result |
|---|---|
| Local build, Apple Development signature, installation | passed; `.local/pessimistic-twin/installed-receipt.json` |
| Live session continuity | 26 shell PIDs preserved; layout and settings unchanged |
| Installed identity | 123 built/installed file hashes matched; running executable and helper API identity verified |
| Authenticated provider/fork/hook, PTY and physical GUI/E2E verification | paused by user; no Twin fork started during verification |

- **Sandbox and provider runtime**: Native Codex generated-policy checks and installed Anthropic `sandbox-runtime 0.0.37` primitive proofs do not qualify embedded `Claude 2.1.323`, authenticated fork identity, or live provider hook execution.
- **Original-source hook trust**: The original source conversation still relies on its existing trusted hook pipeline; Twin C-helper admission authenticates Twin reviewer hooks only, not original source hook callers.
- **External filesystem writers**: Runtime locks serialize participating Trano operations, not external editors or host processes. Pre-launch, pre-commit, and cleanup process-use rechecks detect and refuse observed divergence, rather than providing global atomic filesystem isolation.

The concrete unit acceptance hooks below map requirements to test classes and do not establish whole-product coverage or passing status.

| Requirements | Test classes |
| --- | --- |
| FR-TWIN-1 | `PessimisticTwinRuntimeGateTests`, `PessimisticTwinAPITests`, `PessimisticTwinNativeButtonTests`, `PessimisticTwinSourceExpectationTests` |
| FR-TWIN-2 | `PessimisticTwinGitTests`, `PessimisticTwinGitPathTests`, `PessimisticTwinGitPlumbingTests`, `PessimisticTwinLaunchPreparationTests` |
| FR-TWIN-3 | `PessimisticTwinProviderTests`, `PessimisticTwinProfileTests`, `PessimisticTwinLaunchPreparationTests`, `PessimisticTwinLaunchFileTests`, `PessimisticTwinRunCLITests`, `PessimisticTwinAuthenticationTests`, `PessimisticTwinRestrictedStartupTests` |
| FR-TWIN-4 | `PessimisticTwinSandboxTests`, `PessimisticTwinPrivateReadTests`, `PessimisticTwinBridgeCLITests` |
| FR-TWIN-5 | `PessimisticTwinModelTests`, `PessimisticTwinRuntimeGitWorkTests`, `PessimisticTwinHookAdmissionTests` |
| FR-TWIN-6 | `PessimisticTwinDecisionGuardTests`, `PessimisticTwinAPITests`, `PessimisticTwinSourceIdleTests` |
| FR-TWIN-7 | `PessimisticTwinGitTests`, `PessimisticTwinLifecycleTests`, `PessimisticTwinInvocationInputTests` |
| FR-TWIN-8 | `PessimisticTwinCoordinatorTests`, `PessimisticTwinStoreTests`, `PessimisticTwinReservationTests` |
| FR-TWIN-9 | `PessimisticTwinGitPathTests`, `PessimisticTwinStoreTests`, `PessimisticTwinReservationTests` |
| FR-TWIN-10 | `PessimisticTwinGitPlumbingTests`, `PessimisticTwinRuntimeGateTests`, `PessimisticTwinRunCLITests` |
