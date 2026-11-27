import Foundation
import XCTest
import Darwin
@testable import TerminalCore

final class WorktreeCleanupTests: XCTestCase {
    // Implements: FR-WT-1, FR-WT-2, FR-WT-3, FR-WT-4, FR-WT-7
    func testOnlySuccessfulExactNewWorktreeBecomesTrackedAndExistingTreesStayUnowned() throws {
        let f = try fixture(); defer { f.remove() }
        let capture = try XCTUnwrap(f.coordinator.beginCapture(owner:f.owner,cwd:"/repo",gitArguments:["worktree","add","/new"],now:f.now))
        XCTAssertEqual(try f.store.load().captures.count,1)
        try f.coordinator.finishCapture(id:capture.id,nonce:capture.nonce,exitStatus:0,now:f.now)
        let records = try f.coordinator.status()
        XCTAssertEqual(records.count,1)
        XCTAssertEqual(records.first?.identity,f.git.created.identity)
        XCTAssertEqual(records.first?.owner,f.owner)
        XCTAssertEqual(records.first?.status,.tracked)
        XCTAssertTrue(try f.store.load().captures.isEmpty)
        XCTAssertEqual(f.backend.removals,0)
    }

    func testFailureWrongNonceAndWrongRequestedDeltaNeverCreateAutomaticTargets() throws {
        for variant in ["failure","nonce","delta"] {
            let f = try fixture(); defer { f.remove() }
            let capture = try XCTUnwrap(f.coordinator.beginCapture(owner:f.owner,cwd:"/repo",gitArguments:["worktree","add","/new"],now:f.now))
            if variant == "delta" { f.git.created = entry("/different",inode:2) }
            if variant == "nonce" { XCTAssertThrowsError(try f.coordinator.finishCapture(id:capture.id,nonce:"wrong",exitStatus:0,now:f.now)) }
            else { try f.coordinator.finishCapture(id:capture.id,nonce:capture.nonce,exitStatus:variant == "failure" ? 1:0,now:f.now) }
            XCTAssertFalse(try f.coordinator.status().contains { [.tracked,.pending].contains($0.status) })
            XCTAssertEqual(f.backend.removals,0)
        }
    }

    func testConcurrentCaptureIntervalsAreNeverAutomaticallyAttributed() throws {
        let f = try fixture(); defer { f.remove() }
        let first = try XCTUnwrap(f.coordinator.beginCapture(owner:f.owner,cwd:"/repo",gitArguments:["worktree","add","/new"],now:f.now))
        let second = try XCTUnwrap(f.coordinator.beginCapture(owner:f.owner,cwd:"/repo",gitArguments:["worktree","add","/other"],now:f.now))
        try f.coordinator.finishCapture(id:first.id,nonce:first.nonce,exitStatus:0,now:f.now)
        try f.coordinator.finishCapture(id:second.id,nonce:second.nonce,exitStatus:0,now:f.now)
        XCTAssertFalse(try f.coordinator.status().contains { [.tracked,.pending].contains($0.status) })
        XCTAssertEqual(f.backend.removals,0)
    }

    func testParallelCapturesInDifferentRepositoriesBothRetainExactOwnership() throws {
        let f = try fixture(); defer { f.remove() }
        let otherGit = FakeGit(created: entry("/other-new", inode: 3, commonDirectory: "/otherrepo/.git"))
        let other = WorktreeCleanupCoordinator(store: WorktreeCleanupStore(root: f.root), backend: FakeBackend(owner: f.owner, git: otherGit))
        let first = try XCTUnwrap(f.coordinator.beginCapture(owner: f.owner, cwd: "/repo", gitArguments: ["worktree", "add", "/new"], now: f.now))
        let second = try XCTUnwrap(other.beginCapture(owner: f.owner, cwd: "/otherrepo", gitArguments: ["worktree", "add", "/other-new"], now: f.now))
        XCTAssertFalse(first.ambiguous)
        XCTAssertFalse(second.ambiguous)
        XCTAssertTrue(try f.store.load().captures.allSatisfy { !$0.ambiguous })
        try f.coordinator.finishCapture(id: first.id, nonce: first.nonce, exitStatus: 0, now: f.now)
        try other.finishCapture(id: second.id, nonce: second.nonce, exitStatus: 0, now: f.now)
        XCTAssertEqual(try f.coordinator.status().filter { $0.status == .tracked }.count, 2)
    }

    func testBaselineBeforeOtherCaptureFinishesCannotClaimItsExtraCreation() throws {
        let f = try fixture(); defer { f.remove() }
        let first = try XCTUnwrap(f.coordinator.beginCapture(owner: f.owner, cwd: "/repo", gitArguments: ["worktree", "add", "/new"], now: f.now))
        let otherGit = FakeGit(created: entry("/newer", inode: 3))
        let other = WorktreeCleanupCoordinator(store: WorktreeCleanupStore(root: f.root), backend: FakeBackend(owner: f.owner, git: otherGit))
        otherGit.onBoundary = {
            otherGit.onBoundary = nil
            do { try f.coordinator.finishCapture(id: first.id, nonce: first.nonce, exitStatus: 0, now: f.now) }
            catch { XCTFail("Interleaved capture fixture failed: \(error)") }
        }
        let second = try XCTUnwrap(other.beginCapture(owner: f.owner, cwd: "/repo", gitArguments: ["worktree", "add", "/newer"], now: f.now))
        otherGit.afterEntries = [f.git.created, otherGit.created]
        try other.finishCapture(id: second.id, nonce: second.nonce, exitStatus: 0, now: f.now)
        let records = try f.coordinator.status()
        XCTAssertEqual(records.filter { $0.status == .tracked }.map(\.path), ["/new"])
        XCTAssertFalse(records.contains { $0.path == "/newer" })
    }

    func testRemovingRepositoryDoesNotBlockDifferentRepositoryCapture() throws {
        let f = try fixture(); defer { f.remove() }; try tracked(f); try f.coordinator.recordCompletion(f.proof)
        try f.store.transaction { $0.records[0].status = .removing }
        let otherGit = FakeGit(created: entry("/other-new", inode: 3, commonDirectory: "/otherrepo/.git"))
        let other = WorktreeCleanupCoordinator(store: WorktreeCleanupStore(root: f.root), backend: FakeBackend(owner: f.owner, git: otherGit))
        XCTAssertNotNil(try other.beginCapture(owner: f.owner, cwd: "/otherrepo", gitArguments: ["worktree", "add", "/other-new"], now: f.now))
        XCTAssertNil(try f.coordinator.beginCapture(owner: f.owner, cwd: "/repo", gitArguments: ["worktree", "add", "/newer"], now: f.now))
    }

    func testDifferentRepositoryCaptureDoesNotStallEligibleCleanup() throws {
        let f = try fixture(); defer { f.remove() }; try tracked(f); try f.coordinator.recordCompletion(f.proof)
        let otherGit = FakeGit(created: entry("/other-new", inode: 3, commonDirectory: "/otherrepo/.git"))
        let other = WorktreeCleanupCoordinator(store: WorktreeCleanupStore(root: f.root), backend: FakeBackend(owner: f.owner, git: otherGit))
        XCTAssertNotNil(try other.beginCapture(owner: f.owner, cwd: "/otherrepo", gitArguments: ["worktree", "add", "/other-new"], now: f.now))
        _ = try f.coordinator.processPending(now: f.now.addingTimeInterval(31))
        XCTAssertEqual(f.backend.removals, 1)
    }

    func testSameRepositoryCaptureStillHoldsEligibleCleanup() throws {
        let f = try fixture(); defer { f.remove() }; try tracked(f); try f.coordinator.recordCompletion(f.proof)
        XCTAssertNotNil(try f.coordinator.beginCapture(owner: f.owner, cwd: "/repo", gitArguments: ["worktree", "add", "/newer"], now: f.now))
        _ = try f.coordinator.processPending(now: f.now.addingTimeInterval(31))
        XCTAssertEqual(f.backend.removals, 0)
    }

    func testTrustedMatchingCompletionWaitsThirtySecondsAndRemovesOnlyAfterRevalidation() throws {
        let f = try fixture(); defer { f.remove() }
        try tracked(f)
        try f.coordinator.recordCompletion(f.proof)
        XCTAssertEqual(try f.coordinator.status().first?.eligibleAt,f.now.addingTimeInterval(30))
        XCTAssertTrue(try f.coordinator.processPending(now:f.now.addingTimeInterval(29)).isEmpty)
        XCTAssertEqual(f.backend.removals,0)
        let changed = try f.coordinator.processPending(now:f.now.addingTimeInterval(30))
        XCTAssertEqual(changed.first?.status,.removed)
        XCTAssertEqual(f.backend.removals,1)
        _ = try f.coordinator.processPending(now:f.now.addingTimeInterval(60))
        XCTAssertEqual(f.backend.removals,1)
    }

    func testStaleCompletionOrOwnerCannotScheduleCurrentWorktree() throws {
        let f = try fixture(); defer { f.remove() }; try tracked(f)
        let stale = WorktreeCompletionProof(owner:f.owner,completionID:"old",turnID:"old",completedAt:f.now)
        XCTAssertThrowsError(try f.coordinator.recordCompletion(stale))
        XCTAssertEqual(try f.coordinator.status().first?.status,.tracked)
        XCTAssertEqual(f.backend.removals,0)
    }

    func testEveryContextSafetyGatePreventsDeletionAndFinalPreferenceDisableWins() throws {
        for gate in ["disabled","remote","owner","completion","turn","busy","input","revision","tools","decision","queue","quota","cwd","final"] {
            let f = try fixture(); defer { f.remove() }; try tracked(f); try f.coordinator.recordCompletion(f.proof)
            f.backend.gate = gate
            _ = try f.coordinator.processPending(now:f.now.addingTimeInterval(31))
            XCTAssertEqual(f.backend.removals,0,gate)
            XCTAssertNotEqual(try f.coordinator.status().first?.status,.removed,gate)
        }
    }

    func testEveryGitAndProcessSafetyFactPreventsRemoval() throws {
        for gate in ["dirty","ignored","main","bare","locked","prunable","identity","operation","retention","process","uncertain"] {
            let f = try fixture(); defer { f.remove() }; try tracked(f); try f.coordinator.recordCompletion(f.proof)
            f.git.gate = gate
            _ = try f.coordinator.processPending(now:f.now.addingTimeInterval(31))
            XCTAssertEqual(f.backend.removals,0,gate)
            XCTAssertEqual(try f.coordinator.status().first?.status,.held,gate)
        }
    }

    func testInterruptedRemovingRecordBecomesReviewRequiredWithoutAutomaticRetry() throws {
        let f = try fixture(); defer { f.remove() }; try tracked(f); try f.coordinator.recordCompletion(f.proof)
        try f.store.transaction { $0.records[0].status = .removing }
        _ = try f.coordinator.processPending(now:f.now.addingTimeInterval(31))
        let record = try XCTUnwrap(f.coordinator.status().first)
        XCTAssertEqual(record.status,.needsReview)
        XCTAssertThrowsError(try f.coordinator.retry(id:record.id,now:f.now.addingTimeInterval(32)))
        XCTAssertEqual(f.backend.removals,0)
    }

    func testHeldRecordCanRetryAfterSafetyBlockClearsWithoutForcingOrDeletingBranches() throws {
        let f = try fixture(); defer { f.remove() }; try tracked(f); try f.coordinator.recordCompletion(f.proof)
        f.git.gate = "dirty"; _ = try f.coordinator.processPending(now:f.now.addingTimeInterval(31))
        let record = try XCTUnwrap(f.coordinator.status().first)
        f.git.gate = nil
        try f.coordinator.retry(id:record.id,now:f.now.addingTimeInterval(32))
        _ = try f.coordinator.processPending(now:f.now.addingTimeInterval(33))
        XCTAssertEqual(f.backend.removals,1)
        XCTAssertEqual(try f.coordinator.status().first?.status,.removed)
    }

    func testDisabledCreationDoesNotOwnWorktreesForLaterEnable() throws {
        let f = try fixture(); defer { f.remove() }; f.backend.gate = "disabled"
        XCTAssertNil(try f.coordinator.beginCapture(owner:f.owner,cwd:"/repo",gitArguments:["worktree","add","/new"],now:f.now))
        XCTAssertTrue(try f.store.load().captures.isEmpty)
        XCTAssertTrue(try f.coordinator.status().isEmpty)
        XCTAssertEqual(f.git.snapshots,0)
    }

    func testStoredEligibilityCannotShortenTheThirtySecondCompletionGrace() throws {
        let f = try fixture(); defer { f.remove() }; try tracked(f); try f.coordinator.recordCompletion(f.proof)
        XCTAssertThrowsError(try f.store.transaction { $0.records[0].eligibleAt = f.now })
        XCTAssertEqual(try f.coordinator.status().first?.eligibleAt, f.now.addingTimeInterval(30))
    }

    func testInputRevisionChangeDuringInspectionPreventsRemovalEvenWhenInputReturnsReady() throws {
        let f = try fixture(); defer { f.remove() }; try tracked(f); try f.coordinator.recordCompletion(f.proof)
        f.git.onBoundary = { f.backend.inputRevision += 1 }
        _ = try f.coordinator.processPending(now: f.now.addingTimeInterval(31))
        XCTAssertEqual(f.backend.removals, 0)
        XCTAssertEqual(try f.coordinator.status().first?.status, .held)
    }

    func testRuntimeGitAndProcessBoundariesNeverHoldMetadataTransactionLock() throws {
        let f = try fixture(); defer { f.remove() }
        let check = {
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { completed.signal() }
                do { try WorktreeCleanupStore(root: f.root).transaction { _ in } }
                catch { XCTFail("Metadata boundary failed: \(error)") }
            }
            XCTAssertEqual(completed.wait(timeout: .now() + 0.5), .success, "External work held the sidecar metadata lock")
        }
        f.backend.onBoundary = check; f.git.onBoundary = check
        try tracked(f); try f.coordinator.recordCompletion(f.proof)
        _ = try f.coordinator.processPending(now: f.now.addingTimeInterval(31))
        XCTAssertEqual(f.backend.removals, 1)
    }

    func testCleanupLeaseExcludesOtherWorkerButNeverBlocksStatusRead() throws {
        let f = try fixture(); defer { f.remove() }
        try tracked(f)
        let result = try f.store.withCleanupLease { () -> Bool in
            XCTAssertNil(try WorktreeCleanupStore(root: f.root).withCleanupLease { true })
            XCTAssertEqual(try WorktreeCleanupStore(root: f.root).load().records.count, 1)
            return true
        }
        XCTAssertEqual(result, true)
    }

    func testSidecarRejectsCorruptSymlinkFIFOHardlinkOversizedAndPublicState() throws {
        for kind in ["corrupt", "symlink", "fifo", "hardlink", "oversized", "public"] {
            let f = try fixture(); defer { f.remove() }
            let path = f.root.appendingPathComponent("worktree-cleanup.json").path
            switch kind {
            case "corrupt": try Data("broken".utf8).write(to: URL(fileURLWithPath: path)); _ = chmod(path, 0o600)
            case "symlink": XCTAssertEqual(symlink("missing", path), 0)
            case "fifo": XCTAssertEqual(mkfifo(path, 0o600), 0)
            case "hardlink":
                let other = f.root.appendingPathComponent("other").path
                XCTAssertEqual(close(open(other, O_CREAT | O_WRONLY, 0o600)), 0); XCTAssertEqual(link(other, path), 0)
            case "oversized": try Data(repeating: 65, count: 1_048_577).write(to: URL(fileURLWithPath: path)); _ = chmod(path, 0o600)
            default: try Data("null".utf8).write(to: URL(fileURLWithPath: path)); _ = chmod(path, 0o644)
            }
            XCTAssertThrowsError(try f.store.load(), kind)
            XCTAssertThrowsError(try f.coordinator.beginCapture(owner: f.owner, cwd: "/repo", gitArguments: ["worktree", "add", "/new"], now: f.now), kind)
            XCTAssertEqual(f.backend.removals, 0)
        }
    }

    func testCaptureAndHistoryBoundsFailBeforeOwningMoreWorkAndRootRemainsPrivate() throws {
        let f = try fixture(); defer { f.remove() }
        let capture = try XCTUnwrap(f.coordinator.beginCapture(owner: f.owner, cwd: "/repo", gitArguments: ["worktree", "add", "/new"], now: f.now))
        try f.store.transaction { state in
            state.captures = (0..<32).map { _ in WorktreeCapture(id: UUID().uuidString.lowercased(), nonce: UUID().uuidString.lowercased(), owner: f.owner, startedAt: f.now, invocation: capture.invocation, ambiguous: true) }
        }
        XCTAssertNil(try f.coordinator.beginCapture(owner: f.owner, cwd: "/repo", gitArguments: ["worktree", "add", "/more"], now: f.now))
        let attrs = try FileManager.default.attributesOfItem(atPath: f.root.appendingPathComponent("worktree-cleanup.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    private func tracked(_ f: Fixture) throws {
        let capture = try XCTUnwrap(f.coordinator.beginCapture(owner:f.owner,cwd:"/repo",gitArguments:["worktree","add","/new"],now:f.now))
        try f.coordinator.finishCapture(id:capture.id,nonce:capture.nonce,exitStatus:0,now:f.now)
    }
    private func entry(_ path:String,inode:UInt64,commonDirectory:String="/repo/.git") -> WorktreeSnapshotEntry {
        let node = WorktreeFileIdentity(device:1,inode:inode)
        let identity = WorktreeIdentity(path:path,commonDirectory:commonDirectory,adminDirectory:commonDirectory+"/worktrees/new",pathIdentity:node,gitFileIdentity:node,adminIdentity:node,commonIdentity:WorktreeFileIdentity(device:1,inode:1))
        return WorktreeSnapshotEntry(path:path,head:String(repeating:"a",count:40),branch:"refs/heads/task",identity:identity)
    }
    private struct Fixture {
        let root:URL;let store:WorktreeCleanupStore;let backend:FakeBackend;let owner:WorktreeOwner;let now:Date
        var git:FakeGit {backend.gitFake}
        var coordinator:WorktreeCleanupCoordinator {WorktreeCleanupCoordinator(store:store,backend:backend)}
        var proof:WorktreeCompletionProof {WorktreeCompletionProof(owner:owner,completionID:"completion",turnID:"turn",completedAt:now)}
        func remove(){try? FileManager.default.removeItem(at:root)}
    }
    private func fixture()throws->Fixture {
        let root=URL(fileURLWithPath:"/tmp/trano-wt-unit-"+UUID().uuidString.prefix(8))
        guard mkdir(root.path,0o700)==0 else {throw TerminalError.runtime("Fixture mkdir")}
        let owner=WorktreeOwner(paneID:UUID().uuidString.lowercased(),generation:UUID().uuidString.lowercased(),backendPID:123,
            processIdentity:SupervisorProcessIdentity(pid:123,ownerUID:getuid(),startedAtSeconds:1,startedAtMicroseconds:1))
        let git=FakeGit(created:entry("/new",inode:2));let backend=FakeBackend(owner:owner,git:git)
        return Fixture(root:root,store:WorktreeCleanupStore(root:root),backend:backend,owner:owner,now:Date(timeIntervalSince1970:100))
    }
    private final class FakeBackend:WorktreeCleanupBackend {
        let owner:WorktreeOwner;let gitFake:FakeGit;var gate:String?;var removals=0;var inputRevision:UInt64=0;var onBoundary:(()->Void)?
        var git:WorktreeGitInspecting {gitFake}
        init(owner:WorktreeOwner,git:FakeGit){self.owner=owner;self.gitFake=git}
        func context(owner:WorktreeOwner)throws->WorktreeCleanupContext {
            onBoundary?()
            return WorktreeCleanupContext(enabled:gate != "disabled",local:gate != "remote",owner:gate == "owner" ? nil:self.owner,
                completionID:gate == "completion" ? "other":"completion",turnID:gate == "turn" ? "other":"turn",
                idle:gate != "busy",inputClear:gate != "input",inputRevision:gate == "revision" ? nil:inputRevision,hasActiveTools:gate == "tools",hasPendingDecisions:gate == "decision",
                hasQueuedWork:gate == "queue",quotaSwitching:gate == "quota",sessionCWDs:gate == "cwd" ? ["/new/subdirectory"]:[])
        }
        func commitRemoval(record:WorktreeCleanupRecord,expectedContext:WorktreeCleanupContext)throws {
            onBoundary?()
            if gate == "final" {throw TerminalError.invalid("Preference disabled at final commit")}
            let fresh=try context(owner:record.owner)
            guard fresh==expectedContext else {throw TerminalError.invalid("Context changed")}
            try WorktreeCleanupPolicy.validate(record:record,context:fresh)
            try gitFake.remove(record.identity);removals += 1
        }
    }
    private final class FakeGit:WorktreeGitInspecting {
        var created:WorktreeSnapshotEntry;var snapshots=0;var gate:String?;var afterEntries:[WorktreeSnapshotEntry]?;var onBoundary:(()->Void)?
        init(created:WorktreeSnapshotEntry){self.created=created}
        func creationInvocation(cwd:String,gitArguments:[String])throws->WorktreeCreationInvocation? {
            WorktreeCreationInvocation(cwd:cwd,gitArguments:gitArguments,targetPath:gitArguments.last ?? "")
        }
        func snapshot(cwd:String,gitArguments:[String])throws->WorktreeRepositorySnapshot {
            onBoundary?()
            snapshots += 1
            let common = created.identity?.commonDirectory ?? "/repo/.git"
            let main=WorktreeSnapshotEntry(path:URL(fileURLWithPath:common).deletingLastPathComponent().path,isMain:true)
            return WorktreeRepositorySnapshot(commonDirectory:common,commonIdentity:WorktreeFileIdentity(device:1,inode:1),worktrees:snapshots == 1 ? [main]:[main]+(afterEntries ?? [created]))
        }
        func inspect(_ identity:WorktreeIdentity)throws->WorktreeInspection {
            onBoundary?()
            let current=WorktreeSnapshotEntry(path:created.path,head:created.head,branch:created.branch,isMain:gate == "main",isBare:gate == "bare",
                locked:gate == "locked",prunable:gate == "prunable",identity:gate == "identity" ? nil:created.identity)
            return WorktreeInspection(entry:current,clean:gate != "dirty",hasIgnored:gate == "ignored",operationInProgress:gate == "operation",retainedHEAD:gate != "retention")
        }
        func remove(_ identity:WorktreeIdentity)throws {onBoundary?()}
        func processUse(path:String)throws->WorktreeProcessUse {onBoundary?();return gate == "process" ? .inUse:gate == "uncertain" ? .uncertain:.unused}
    }
}
