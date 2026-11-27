import Darwin
import Foundation
import XCTest
@testable import TerminalCore

final class SupervisorContinuationTests: XCTestCase {
    // Implements: FR-SUP-6, FR-QUEUE-6
    func testTrustedDoneUsesSharedLeaseExactlyOnceAndKeepsUnicodeText() throws {
        let fixture = try Fixture()
        let request = try fixture.request(text: "다음 작업\n따옴표 ' \" ; 끝")
        let result = try fixture.coordinator.continueWork(request)
        XCTAssertEqual(result.paneID, fixture.target.paneID)
        XCTAssertEqual(result.generation, fixture.target.generation)
        XCTAssertEqual(fixture.backend.writes, [request.text])
        XCTAssertEqual(fixture.backend.events, ["reserved", "write", "finished"])
        XCTAssertThrowsError(try fixture.coordinator.continueWork(request))
        XCTAssertEqual(fixture.backend.writes.count, 1)
    }

    // Implements: FR-SUP-6
    func testDoneAndInputLeaseDoNotBypassDecisionsQueueQuotaOrTrustedCompletion() throws {
        for mutate in [
            { (c: inout SupervisorContinuationCandidate) in c.activity = .running },
            { $0.activitySource = "osc" }, { $0.alive = false }, { $0.local = false },
            { $0.completionID = nil }, { $0.consumedCompletionID = $0.completionID },
            { $0.completionOriginExited = false }, { $0.completionProviderVerified = false },
            { $0.pendingDecision = true }, { $0.queuedInput = true }, { $0.quotaHandoff = true },
            { $0.quotaLimited = true }, { $0.safeTurnBoundary = false }
        ] {
            let fixture = try Fixture()
            let request = try fixture.request()
            mutate(&fixture.backend.candidate)
            XCTAssertThrowsError(try fixture.coordinator.continueWork(request))
            XCTAssertTrue(fixture.backend.writes.isEmpty)
        }
        let fixture = try Fixture()
        fixture.backend.candidate.completedAt = fixture.now
        XCTAssertNil(fixture.backend.candidate.offer(now: fixture.now))
    }

    // Implements: FR-SUP-6
    func testCapturedTargetIdentityAndSupervisorAuthorityNeverAdoptReplacements() throws {
        let fixture = try Fixture()
        let request = try fixture.request()
        let changed = fixture.identity(paneID: fixture.target.paneID, generation: UUID().uuidString)
        fixture.backend.candidate = fixture.candidate(target: changed)
        XCTAssertThrowsError(try fixture.coordinator.continueWork(request))
        fixture.backend.candidate = fixture.candidate(target: fixture.target)
        fixture.backend.authority = fixture.authority(backendBirth: 999)
        XCTAssertThrowsError(try fixture.coordinator.continueWork(request))
        fixture.backend.authority = nil
        XCTAssertThrowsError(try fixture.coordinator.continueWork(request))
        XCTAssertTrue(fixture.backend.writes.isEmpty)
    }

    // Implements: FR-SUP-6, FR-QUEUE-5
    func testManualDraftBetweenReadinessAndCommitIsNeverAppendedOrSubmitted() throws {
        let fixture = try Fixture()
        let request = try fixture.request()
        fixture.backend.beforeCommit = {
            let receipt = try fixture.backend.ledger.beginManualWrite(binding: request.offer.lease.binding)
            fixture.backend.ledger.finishWrite(receipt, succeeded: true)
        }
        XCTAssertThrowsError(try fixture.coordinator.continueWork(request))
        XCTAssertTrue(fixture.backend.writes.isEmpty)
        XCTAssertTrue(fixture.backend.events.isEmpty)
    }

    // Implements: FR-SUP-6
    func testAmbiguousWriteCannotReplayLeaseOrCompletedTurn() throws {
        let fixture = try Fixture()
        let request = try fixture.request()
        fixture.backend.failWrite = true
        XCTAssertThrowsError(try fixture.coordinator.continueWork(request))
        fixture.backend.failWrite = false
        XCTAssertThrowsError(try fixture.coordinator.continueWork(request))
        XCTAssertEqual(fixture.backend.writes, [request.text])
        XCTAssertEqual(fixture.backend.events, ["reserved", "write", "uncertain"])
    }

    // Implements: FR-SUP-7
    func testReviewRetainsUnknownAndNeverWritesOrCreatesAnEmptyInputClaim() throws {
        let fixture = try Fixture()
        let request = try fixture.request()
        try fixture.coordinator.review(authority: request.authority, target: fixture.target)
        XCTAssertEqual(fixture.backend.ledger.readiness(binding: request.offer.lease.binding), .inputReviewRequired)
        XCTAssertThrowsError(try fixture.coordinator.continueWork(request))
        XCTAssertEqual(fixture.backend.reviews, [fixture.target])
        XCTAssertTrue(fixture.backend.writes.isEmpty)
        XCTAssertTrue(fixture.backend.events.isEmpty)
    }

    // Implements: FR-SUP-6, FR-SUP-7
    func testTargetNavigationValidationAllowsWorkingButRejectsStaleDestination() throws {
        let fixture = try Fixture()
        fixture.backend.candidate.activity = .running
        try fixture.coordinator.validateTarget(authority: try XCTUnwrap(fixture.backend.authority), target: fixture.target)
        let other = fixture.identity(paneID: fixture.target.paneID, generation: UUID().uuidString)
        XCTAssertThrowsError(try fixture.coordinator.validateTarget(authority: try XCTUnwrap(fixture.backend.authority), target: other))
        XCTAssertTrue(fixture.backend.writes.isEmpty)
    }

    // Implements: FR-SUP-6
    func testBlankControlsAndOversizedInputRejectBeforeReservation() throws {
        let fixture = try Fixture()
        for text in ["", "  \n", "bad\u{1b}[A", String(repeating: "가", count: 22_000)] {
            XCTAssertThrowsError(try fixture.coordinator.continueWork(fixture.request(text: text)))
        }
        XCTAssertTrue(fixture.backend.events.isEmpty)
        XCTAssertTrue(fixture.backend.writes.isEmpty)
    }

    // Implements: FR-SUP-6, FR-SUP-7
    func testProjectionOffersExactLeaseAndReadinessChangesWakeWithoutProofOrText() throws {
        let fixture = try Fixture()
        let context = try fixture.backend.transaction { try fixture.backend.continuationContext() }
        let authority = try XCTUnwrap(context.authority)
        let before = SupervisorProjection.state(binding: authority.binding, observation: fixture.observation(context: context))
        XCTAssertEqual(before.continuationAuthority, authority)
        let target = try XCTUnwrap(before.targets.first)
        XCTAssertEqual(target.reference, fixture.target)
        XCTAssertEqual(target.continuation, .ready)
        XCTAssertEqual(target.continuationOffer, fixture.backend.candidate.offer(now: fixture.now))
        XCTAssertEqual(target.inputReadiness?.revision, fixture.backend.candidate.readiness.lease?.revision)
        let raw = String(decoding: try JSONEncoder().encode(before.cursor), as: UTF8.self)
        XCTAssertFalse(raw.contains("proofID"))
        XCTAssertFalse(raw.contains("configurationRoot"))
        XCTAssertFalse(raw.contains("text"))
        let receipt = try fixture.backend.ledger.beginManualWrite(binding: try XCTUnwrap(fixture.backend.candidate.readiness.lease).binding)
        fixture.backend.ledger.finishWrite(receipt, succeeded: true)
        let changed = try fixture.backend.transaction { try fixture.backend.continuationContext() }
        let after = SupervisorProjection.state(binding: authority.binding, observation: fixture.observation(context: changed))
        XCTAssertNotEqual(before.cursor, after.cursor)
        XCTAssertEqual(after.targets.first?.inputReadiness?.state, .inputReviewRequired)
        XCTAssertNil(after.targets.first?.continuationOffer)
    }

    // Implements: FR-SUP-6
    func testRuntimeProjectionRequiresExactOwnedLaunchAncestryAndCompletedHook() throws {
        let fixture = try Fixture()
        let authority = try XCTUnwrap(fixture.backend.authority)
        let observation = fixture.observation(context: SupervisorContinuationContext(authority: authority, candidates: []))
        var snapshot = RuntimeState()
        snapshot.sessions = observation.sessions
        snapshot.agentLaunches = observation.launches
        var turn = FollowUpTurn(paneID: fixture.target.paneID, generation: fixture.target.generation)
        turn.completionID = fixture.backend.candidate.completionID
        turn.completedAt = fixture.now.addingTimeInterval(-1)
        turn.completionOriginPID = 99_999
        turn.providerPID = fixture.target.providerPID
        turn.providerIdentity = "\(fixture.target.providerIdentity.startedAtSeconds).0:/synthetic/bin/claude"
        snapshot.followUpTurns = [turn]
        var supervision = AgentSupervision(generation: fixture.target.generation)
        supervision.atTurnBoundary = true
        snapshot.supervision = [supervision]
        var records: [Int32: SupervisorContinuationProcess] = [:]
        for identity in [authority.launch, fixture.target] {
            records[identity.backendPID] = SupervisorContinuationProcess(identity: identity.backendIdentity, parentPID: 1, executable: "/bin/zsh")
            records[identity.providerPID] = SupervisorContinuationProcess(identity: identity.providerIdentity, parentPID: identity.backendPID, executable: "/synthetic/bin/claude")
        }
        func projected(_ value: RuntimeState) -> SupervisorContinuationContext {
            SupervisorContinuationRuntimeProjection.make(snapshot: value, sessions: value.sessions, binding: authority.binding,
                ledger: fixture.backend.ledger, pendingDecisionPaneIDs: [], limitedAccountIDs: [], bootID: "synthetic-boot",
                now: fixture.now, process: { records[$0] }, originExited: { $0 == 99_999 })
        }
        let valid = projected(snapshot)
        XCTAssertEqual(valid.authority, authority)
        XCTAssertEqual(valid.candidates.first?.target, fixture.target)
        XCTAssertNotNil(valid.candidates.first?.offer(now: fixture.now))
        snapshot.agentLaunches.append(snapshot.agentLaunches.first { $0.paneID == fixture.target.paneID }!)
        XCTAssertFalse(projected(snapshot).candidates.contains { $0.target.paneID == fixture.target.paneID })
        snapshot.agentLaunches.removeLast()
        records[fixture.target.providerPID] = SupervisorContinuationProcess(identity: fixture.target.providerIdentity,
            parentPID: 1, executable: "/synthetic/bin/claude")
        XCTAssertFalse(projected(snapshot).candidates.contains { $0.target.paneID == fixture.target.paneID })
    }

    // Implements: FR-SUP-7
    func testLedgerOnlyRefreshRevokesManualDraftWithoutCreatingANewReadyTurn() throws {
        let fixture = try Fixture()
        let context = try fixture.backend.transaction { try fixture.backend.continuationContext() }
        let authority = try XCTUnwrap(context.authority)
        let cached = SupervisorProjection.state(binding: authority.binding, observation: fixture.observation(context: context))
        let binding = try XCTUnwrap(fixture.backend.candidate.readiness.lease).binding
        let receipt = try fixture.backend.ledger.beginManualWrite(binding: binding, submissionCandidate: true,
            capturedAt: fixture.now.addingTimeInterval(1))
        let draft = SupervisorReadinessProjection.refresh(state: cached, ledger: fixture.backend.ledger)
        XCTAssertEqual(draft.targets.first?.inputReadiness?.state, .inputInFlight)
        XCTAssertNil(draft.targets.first?.continuationOffer)
        XCTAssertEqual(draft.targets.first?.continuation, .inputReviewRequired)
        XCTAssertNotEqual(draft.cursor, cached.cursor)
        fixture.backend.ledger.finishWrite(receipt, succeeded: true)
        XCTAssertTrue(fixture.backend.ledger.observeTrustedSubmit(binding: binding, originStartedAt: fixture.now.addingTimeInterval(2)))
        let submitted = SupervisorReadinessProjection.refresh(state: draft, ledger: fixture.backend.ledger)
        XCTAssertEqual(submitted.targets.first?.inputReadiness?.state, .ready)
        XCTAssertNil(submitted.targets.first?.continuationOffer)
        XCTAssertEqual(submitted.targets.first?.continuation, .inputReviewRequired)
        XCTAssertEqual(fixture.backend.writes.count, 0)
    }

    // Implements: FR-SUP-6
    func testCLIAndAPIDispatchTheSameGuardedContinuation() throws {
        for api in [false, true] {
            let fixture = try Fixture()
            let request = try fixture.request(text: "다음 단계\nNFD: 한글")
            let callbacks = try fixture.callbacks()
            let result: JSONValue
            if api {
                result = try XCTUnwrap(SupervisorAPI.route(APIRequest(method: "supervisor.continue",
                    params: ["request": try .encoded(request)]), operations: callbacks))
            } else {
                let raw = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
                result = try SupervisorCommand.perform(arguments: ["continue", raw], defaultCWD: "/tmp", operations: callbacks)
            }
            XCTAssertEqual(result["paneID"], .string(fixture.target.paneID))
            XCTAssertEqual(fixture.backend.writes, [request.text])
        }
    }

    // Implements: FR-SUP-6
    func testContinuationAPIRejectsUnexpectedFieldsAndCLIOversizeBeforeDispatch() throws {
        let fixture = try Fixture()
        let request = try fixture.request()
        let callbacks = try fixture.callbacks()
        let encoded = try JSONValue.encoded(request)
        XCTAssertThrowsError(try SupervisorAPI.route(APIRequest(method: "supervisor.continue",
            params: ["request": encoded, "force": .bool(true)]), operations: callbacks))
        XCTAssertThrowsError(try SupervisorAPI.route(APIRequest(method: "supervisor.continue",
            params: ["request": .string("not an object")]), operations: callbacks))
        XCTAssertThrowsError(try SupervisorCommand.perform(arguments: ["continue", String(repeating: "x", count: 262_145)],
            defaultCWD: "/tmp", operations: callbacks))
        XCTAssertTrue(fixture.backend.writes.isEmpty)
    }

    // Implements: FR-SUP-7
    func testInputOnlyWatchBurstPerformsZeroFullRegistryReadsAfterInitialSnapshot() throws {
        let fixture = try Fixture()
        let context = try fixture.backend.transaction { try fixture.backend.continuationContext() }
        let authority = try XCTUnwrap(context.authority)
        var cached = SupervisorProjection.state(binding: authority.binding, observation: fixture.observation(context: context))
        try fixture.backend.ledger.review(binding: try XCTUnwrap(fixture.backend.candidate.readiness.lease).binding)
        cached = SupervisorReadinessProjection.refresh(state: cached, ledger: fixture.backend.ledger)
        let source = InputWake(events: 10)
        var fullReads = 0
        var metadataReads = 0
        let watcher = SupervisorWatcher(source: source, observe: { fullReads += 1; return cached },
            observeReadiness: { state in metadataReads += 1; return SupervisorReadinessProjection.refresh(state: state, ledger: fixture.backend.ledger) },
            now: { 0 })
        let result = try watcher.wait(after: cached.cursor, timeout: 1)
        XCTAssertEqual(result.reason, .heartbeat)
        XCTAssertEqual(metadataReads, 10)
        XCTAssertEqual(fullReads, 2)
        XCTAssertEqual(source.calls, 11)
    }

    // Implements: FR-SUP-6
    func testRuntimeReservesDurableCompletionBeforeWriterAndNeverRetriesAmbiguity() throws {
        let fixture = try Fixture()
        let request = try fixture.request()
        let root = URL(fileURLWithPath: "/tmp/trano-sup-res-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var turn = FollowUpTurn(paneID: fixture.target.paneID, generation: fixture.target.generation)
        turn.completionID = request.offer.completionID
        try runtime.update { $0.followUpTurns = [turn] }
        var writes = 0
        XCTAssertThrowsError(try runtime.reserveSupervisorContinuation(request.offer) {
            XCTAssertEqual(try runtime.state().followUpTurns.first?.consumedCompletionID, request.offer.completionID)
            writes += 1
            throw TerminalError.runtime("Synthetic ambiguous write")
        })
        XCTAssertEqual(writes, 1)
        XCTAssertThrowsError(try runtime.reserveSupervisorContinuation(request.offer) { writes += 1 })
        XCTAssertEqual(writes, 1)
    }

    // Implements: FR-SUP-7
    func testCorruptInputLedgerRevokesOffersWithoutFullRegistryOrRuntimeMutation() throws {
        let fixture = try Fixture()
        let context = try fixture.backend.transaction { try fixture.backend.continuationContext() }
        let authority = try XCTUnwrap(context.authority)
        let cached = SupervisorProjection.state(binding: authority.binding, observation: fixture.observation(context: context))
        let root = URL(fileURLWithPath: "/tmp/trano-sup-meta-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try TerminalInputLedgerStore(root: root).save(fixture.backend.ledger)
        try Data("{invalid".utf8).write(to: root.appendingPathComponent("input-state/terminal-input.json"))
        let before = try runtime.state().revision
        let refreshed = try runtime.refreshSupervisorInputReadiness(state: cached)
        XCTAssertNil(refreshed.targets.first?.continuationOffer)
        XCTAssertEqual(refreshed.targets.first?.inputReadiness?.state, .changed)
        XCTAssertEqual(try runtime.state().revision, before)
        XCTAssertEqual(refreshed.targets.first?.reference, fixture.target)
    }

    // Implements: FR-SUP-6, FR-SUP-7
    func testStaleObservationContextCannotAdvertiseReadyForReplacedTargetOrSupervisor() throws {
        let fixture = try Fixture()
        let context = try fixture.backend.transaction { try fixture.backend.continuationContext() }
        let authority = try XCTUnwrap(context.authority)
        var changed = fixture.observation(context: context)
        let index = try XCTUnwrap(changed.launches.firstIndex { $0.paneID == fixture.target.paneID })
        changed.launches[index].id = UUID().uuidString
        let targetReplaced = SupervisorProjection.state(binding: authority.binding, observation: changed)
        XCTAssertEqual(targetReplaced.targets.first?.continuation, .inputReviewRequired)
        XCTAssertNil(targetReplaced.targets.first?.continuationOffer)
        changed = fixture.observation(context: context)
        changed.backendIdentities[authority.launch.paneID] = SupervisorProcessIdentity(pid: authority.launch.backendPID,
            ownerUID: getuid(), startedAtSeconds: 999, startedAtMicroseconds: 0)
        let supervisorReplaced = SupervisorProjection.state(binding: authority.binding, observation: changed)
        XCTAssertNil(supervisorReplaced.continuationAuthority)
        XCTAssertNil(supervisorReplaced.targets.first?.continuationOffer)
    }

    // Implements: FR-SUP-6
    func testPublicServiceRegistersGuardedContinueWithoutStartingAServerOrJob() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-sup-api-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = APIService(runtime: runtime)
        let response = service.route(APIRequest(method: "supervisor.continue", params: [:]))
        XCTAssertTrue(response.error?.contains("supervisor.continue requires one request object") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.host.socketPath))
        XCTAssertFalse(runtime.host.isRunning())
        XCTAssertTrue(try runtime.state().sessions.isEmpty)
    }

    // Implements: FR-SUP-6, FR-SUP-7
    func testBundledInstructionsExplainActualContinueAndUnknownReviewContract() {
        let text = SupervisorInstructions.prompt
        for required in ["supervisor continue", "continuationAuthority", "continuationOffer", "Review Input", "future captured"] {
            XCTAssertTrue(text.contains(required), required)
        }
        XCTAssertFalse(text.contains("no trusted idle-and-empty input guard is available"))
        XCTAssertLessThanOrEqual(text.utf8.count, 32_768)
    }

    private final class InputWake: SupervisorWakeSource {
        var remaining: Int
        var calls = 0
        var inputOnlyWake = false
        init(events: Int) { remaining = events }
        func wait(timeout: TimeInterval) throws -> Bool {
            calls += 1
            inputOnlyWake = remaining > 0
            if remaining > 0 { remaining -= 1; return true }
            return false
        }
    }

    private final class Backend: SupervisorContinuationBackend {
        var authority: SupervisorContinuationAuthority?
        var candidate: SupervisorContinuationCandidate
        var ledger: TerminalInputLedger
        var writes: [String] = []
        var events: [String] = []
        var reviews: [SupervisorContinuationIdentity] = []
        var beforeCommit: (() throws -> Void)?
        var failWrite = false
        var depth = 0
        init(authority: SupervisorContinuationAuthority, candidate: SupervisorContinuationCandidate, ledger: TerminalInputLedger) {
            self.authority = authority; self.candidate = candidate; self.ledger = ledger
        }
        func transaction<T>(_ body: () throws -> T) throws -> T {
            depth += 1
            defer { depth -= 1 }
            return try body()
        }
        func continuationContext() throws -> SupervisorContinuationContext {
            XCTAssertGreaterThan(depth, 0)
            var fresh = candidate
            fresh = SupervisorContinuationCandidate(target: fresh.target,
                readiness: ledger.readiness(binding: TerminalInputBinding(paneID: fresh.target.paneID,
                    backendPID: fresh.target.backendPID, generation: fresh.target.generation, providerPID: fresh.target.providerPID)),
                activity: fresh.activity, activitySource: fresh.activitySource, alive: fresh.alive, local: fresh.local,
                completionID: fresh.completionID, consumedCompletionID: fresh.consumedCompletionID, completedAt: fresh.completedAt,
                completionOriginExited: fresh.completionOriginExited, completionProviderVerified: fresh.completionProviderVerified,
                pendingDecision: fresh.pendingDecision, queuedInput: fresh.queuedInput, quotaHandoff: fresh.quotaHandoff,
                quotaLimited: fresh.quotaLimited, safeTurnBoundary: fresh.safeTurnBoundary)
            return SupervisorContinuationContext(authority: authority, candidates: [fresh])
        }
        func reserveAndCommit(_ request: SupervisorContinuationRequest) throws {
            XCTAssertGreaterThan(depth, 0)
            try beforeCommit?()
            let receipt = try ledger.beginAutomaticWrite(request.offer.lease)
            events.append("reserved")
            candidate.consumedCompletionID = request.offer.completionID
            writes.append(request.text); events.append("write")
            ledger.finishWrite(receipt, succeeded: !failWrite)
            if failWrite { events.append("uncertain"); throw TerminalError.runtime("Synthetic partial write") }
            events.append("finished")
        }
        func reviewInput(authority: SupervisorContinuationAuthority, target: SupervisorContinuationIdentity) throws {
            XCTAssertGreaterThan(depth, 0)
            reviews.append(target)
            try ledger.review(binding: TerminalInputBinding(paneID: target.paneID, backendPID: target.backendPID,
                generation: target.generation, providerPID: target.providerPID))
        }
    }

    private final class Fixture {
        let now = Date(timeIntervalSince1970: 1000)
        let target: SupervisorContinuationIdentity
        let backend: Backend
        var coordinator: SupervisorContinuationCoordinator<Backend> { SupervisorContinuationCoordinator(backend: backend, now: { self.now }) }
        init() throws {
            target = Self.identity(paneID: UUID().uuidString, generation: UUID().uuidString, pid: 200)
            var ledger = TerminalInputLedger()
            let binding = TerminalInputBinding(paneID: target.paneID, backendPID: target.backendPID,
                generation: target.generation, providerPID: target.providerPID)
            let receipt = try ledger.beginManualWrite(binding: binding, submissionCandidate: true, capturedAt: now.addingTimeInterval(-3))
            ledger.finishWrite(receipt, succeeded: true)
            XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding, originStartedAt: now.addingTimeInterval(-2)))
            let own = Self.identity(paneID: UUID().uuidString, generation: UUID().uuidString, pid: 100)
            let authority = SupervisorContinuationAuthority(binding: SupervisorBinding(paneID: own.paneID, backendPID: own.backendPID,
                configuration: SupervisorConfiguration(provider: own.provider, cwd: own.cwd), processIdentity: own.backendIdentity), launch: own)
            backend = Backend(authority: authority, candidate: Self.candidate(target: target,
                readiness: ledger.readiness(binding: binding), now: now), ledger: ledger)
        }
        func request(text: String = "Continue the assigned work") throws -> SupervisorContinuationRequest {
            SupervisorContinuationRequest(authority: try XCTUnwrap(backend.authority),
                offer: try XCTUnwrap(backend.candidate.offer(now: now)), text: text)
        }
        func candidate(target: SupervisorContinuationIdentity) -> SupervisorContinuationCandidate {
            Self.candidate(target: target, readiness: backend.ledger.readiness(binding: TerminalInputBinding(paneID: target.paneID,
                backendPID: target.backendPID, generation: target.generation, providerPID: target.providerPID)), now: now)
        }
        func identity(paneID: String, generation: String) -> SupervisorContinuationIdentity { Self.identity(paneID: paneID, generation: generation, pid: 200) }
        func authority(backendBirth: UInt64) -> SupervisorContinuationAuthority {
            let own = Self.identity(paneID: backend.authority!.launch.paneID, generation: backend.authority!.launch.generation, pid: 100, birth: backendBirth)
            return SupervisorContinuationAuthority(binding: SupervisorBinding(paneID: own.paneID, backendPID: own.backendPID,
                configuration: SupervisorConfiguration(provider: own.provider, cwd: own.cwd), processIdentity: own.backendIdentity), launch: own)
        }
        func observation(context: SupervisorContinuationContext) -> SupervisorObservation {
            let authority = backend.authority!
            let identities = [authority.launch, target]
            let sessions = identities.map { identity -> TerminalSession in
                var session = TerminalSession(id: identity.paneID, title: "Synthetic", cwd: identity.cwd, pid: identity.backendPID)
                session.agent = identity.provider; session.activity.state = .done; session.activity.source = "hook"
                return session
            }
            let launches = identities.map { identity -> AgentLaunch in
                var launch = AgentLaunch(paneID: identity.paneID, provider: identity.provider, providerSessionID: identity.providerSessionID,
                    cwd: identity.cwd, accountID: identity.accountID, configurationRoot: identity.configurationRoot,
                    bootID: "synthetic-boot", processID: identity.backendPID, providerPID: identity.providerPID)
                launch.id = identity.generation
                return launch
            }
            return SupervisorObservation(sessions: sessions, launches: launches,
                backendIdentities: [authority.launch.paneID: authority.launch.backendIdentity], continuationContext: context)
        }
        func callbacks() throws -> SupervisorCommandOperations {
            let context = try backend.transaction { try backend.continuationContext() }
            let state = SupervisorProjection.state(binding: backend.authority?.binding, observation: observation(context: context))
            return SupervisorCommandOperations(state: { state }, start: { _ in state }, stop: { _, _ in state },
                continueWork: { try self.coordinator.continueWork($0) }, watch: { _, _ in SupervisorWatchResult(reason: .heartbeat, state: state) })
        }
        private static func candidate(target: SupervisorContinuationIdentity, readiness: TerminalInputReadiness, now: Date) -> SupervisorContinuationCandidate {
            SupervisorContinuationCandidate(target: target, readiness: readiness, activity: .done, activitySource: "hook",
                completionID: UUID().uuidString, completedAt: now.addingTimeInterval(-1), completionOriginExited: true,
                completionProviderVerified: true, safeTurnBoundary: true)
        }
        private static func identity(paneID: String, generation: String, pid: Int32, birth: UInt64 = 900) -> SupervisorContinuationIdentity {
            SupervisorContinuationIdentity(paneID: paneID, backendPID: pid,
                backendIdentity: SupervisorProcessIdentity(pid: pid, ownerUID: getuid(), startedAtSeconds: birth, startedAtMicroseconds: 0),
                generation: generation, provider: .claude, providerPID: pid + 1,
                providerIdentity: SupervisorProcessIdentity(pid: pid + 1, ownerUID: getuid(), startedAtSeconds: birth + 1, startedAtMicroseconds: 0),
                providerSessionID: UUID().uuidString, configurationRoot: "/synthetic/profile", cwd: "/synthetic/project", providerExecutable: "/synthetic/bin/claude")
        }
    }
}
