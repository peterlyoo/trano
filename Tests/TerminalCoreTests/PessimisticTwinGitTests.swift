import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinGitTests: XCTestCase {
    // Implements: FR-TWIN-2, FR-TWIN-5, FR-TWIN-7, FR-TWIN-9
    func testNulPathsPreserveUnicodeNewlineAndRejectIncompleteOrEscapingNames() throws {
        XCTAssertEqual(try TwinGitService.parsePaths(Data("tracked\0한글\nfile\0".utf8)), ["tracked", "한글\nfile"])
        let decomposed = "e\u{301}"
        XCTAssertEqual(Array(try TwinGitService.parsePaths(Data((decomposed + "\0").utf8))[0].utf8), Array(decomposed.utf8))
        XCTAssertThrowsError(try TwinGitService.parsePaths(Data(("é\0" + decomposed + "\0").utf8)))
        for invalid in [Data("missing terminator".utf8), Data("../outside\0".utf8), Data("/absolute\0".utf8), Data(".git/config\0".utf8), Data([255, 0])] {
            XCTAssertThrowsError(try TwinGitService.parsePaths(invalid))
        }
    }
    func testOwnedBranchNamespaceRejectsOriginalRefAndPathInjection() throws {
        XCTAssertEqual(try TwinGitService.checkedBranch(runID: twinGitFixtureID, round: 2), "refs/heads/trano/twins/" + twinGitFixtureID + "/round-2")
        for invalid in ["main", "../other", "--force", twinGitFixtureID + "/../main"] { XCTAssertThrowsError(try TwinGitService.checkedBranch(runID: invalid, round: 2)) }
        XCTAssertThrowsError(try TwinGitService.checkedBranch(runID: twinGitFixtureID, round: 0))
    }
    func testSnapshotIncludesCurrentUntrackedBinarySymlinkDeletionAndPreservesSource() throws {
        let fixture = TwinGitFixture()
        let before = fixture.fs.sourceBytes
        let snapshot = try fixture.snapshot()
        XCTAssertEqual(fixture.fs.sourceBytes, before)
        let backup = URL(fileURLWithPath: snapshot.worktreePath).deletingLastPathComponent().appendingPathComponent("source-index.backup").path
        XCTAssertEqual(try fixture.fs.read(backup, limit: 1024), before["/source/.git/index"]?.data)
        XCTAssertEqual(fixture.git.sourceHead, fixture.git.initialHead)
        let tree = try XCTUnwrap(fixture.git.trees[snapshot.sourceTree])
        XCTAssertEqual(tree["new 한글\nfile.bin"]?.data, Data([0, 1, 255, 10]))
        XCTAssertEqual(tree["link"]?.mode, "120000")
        XCTAssertEqual(tree["link"]?.data, Data("../external".utf8))
        XCTAssertEqual(tree["tracked.txt"]?.data, Data("latest working bytes\n".utf8))
        XCTAssertNil(tree["deleted.txt"])
        XCTAssertNil(tree["ignored.secret"])
        XCTAssertTrue(fixture.git.calls.filter { $0.command.first == "read-tree" && $0.command.contains("--empty") }.allSatisfy { $0.environment["GIT_INDEX_FILE"]?.hasPrefix("/runtime/twins/") == true })
        XCTAssertTrue(fixture.git.calls.filter { $0.command.first == "hash-object" }.allSatisfy { $0.command.contains("--no-filters") })
        XCTAssertFalse(fixture.git.calls.contains { $0.command.first == "add" || $0.command.first == "commit" || $0.command.first == "stash" || $0.command.contains("--force") })
    }
    func testSnapshotRejectsConcurrentWorkingFileChangesBeforeWorktreeCreation() throws {
        let fixture = TwinGitFixture(); var changed = false
        fixture.git.observe = { call in
            if call.command.first == "hash-object", !changed { changed = true; fixture.fs.file("/source/tracked.txt", Data("new concurrent bytes".utf8)) }
        }
        XCTAssertThrowsError(try fixture.snapshot())
        XCTAssertFalse(fixture.git.calls.contains { $0.command.first == "worktree" && $0.command.contains("add") })
        XCTAssertEqual(fixture.git.sourceHead, fixture.git.initialHead)
    }
    func testUnsupportedFiltersDriversSparseHiddenAndSubmoduleStatesFailBeforeCheckout() throws {
        for setting in ["filter", "driver", "sparse", "hidden", "submodule", "union", "shared"] {
            let fixture = TwinGitFixture(); fixture.git.unsafe = setting
            XCTAssertThrowsError(try fixture.snapshot(), setting)
            XCTAssertFalse(fixture.git.calls.contains { $0.command.first == "worktree" && $0.command.contains("add") || $0.command.first == "hash-object" }, setting)
        }
    }
    func testRuntimeWithinSourceIsRefusedBeforeCreatingAnySourceDirectory() throws {
        let fixture = TwinGitFixture(); let before = fixture.fs.directories
        let service = TwinGitService(root: URL(fileURLWithPath: "/source/runtime"), runner: fixture.git, fileSystem: fixture.fs, inspector: fixture.inspector)
        let identity = SupervisorProcessIdentity(pid: 42, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 1)
        let source = TwinSourceBinding(paneID: UUID().uuidString.lowercased(), generation: UUID().uuidString.lowercased(), conversationID: UUID().uuidString.lowercased(), cwd: "/source", configurationRoot: "/profile", provider: .claude, backendPID: 42, providerPID: 43, backendIdentity: identity, providerIdentity: identity)
        XCTAssertThrowsError(try service.snapshot(source: source, runID: twinGitFixtureID, round: 1))
        XCTAssertEqual(fixture.fs.directories, before)
    }
    func testCorruptOwnedReceiptCannotAuthorizeMergeOrCleanup() throws {
        let fixture = TwinGitFixture(), snapshot = try fixture.snapshot()
        let receipt = URL(fileURLWithPath: snapshot.worktreePath).deletingLastPathComponent().appendingPathComponent("snapshot-receipt.json").path
        fixture.fs.file(receipt, Data("{}".utf8))
        let before = fixture.git.calls.count
        XCTAssertThrowsError(try fixture.service.cleanup(snapshot: snapshot, expectedTip: snapshot.snapshotCommit))
        let result = try fixture.service.merge(snapshot: snapshot, tip: snapshot.snapshotCommit, committing: { try $0() })
        guard case .held = result else { return XCTFail("Corrupt receipt must hold") }
        XCTAssertFalse(fixture.git.calls.dropFirst(before).contains { ["update-ref", "merge"].contains($0.command.first ?? "") })
    }
    func testSnapshotRefusesExistingOwnedLookingBranchWithoutTakingItOver() throws {
        let fixture = TwinGitFixture(); fixture.git.twinBranch = try TwinGitService.checkedBranch(runID: twinGitFixtureID, round: 1); fixture.git.twinHead = fixture.git.initialHead
        XCTAssertThrowsError(try fixture.snapshot())
        XCTAssertFalse(fixture.git.calls.contains { $0.command.first == "worktree" && $0.command.contains("add") })
    }
    func testTrustedCommitUpdatesOnlyTwinRefAndItsIndexWithoutRunningHooks() throws {
        let fixture = TwinGitFixture(), snapshot = try fixture.snapshot()
        let source = fixture.fs.sourceBytes
        fixture.fs.file(snapshot.worktreePath + "/tracked.txt", Data("review fix\n".utf8))
        var stages: [TwinGitMutationStage] = []
        let review = try fixture.service.commit(snapshot: snapshot, message: "Fix reviewed edge case", recordMutation: { stages.append($0) })
        XCTAssertTrue(review.clean); XCTAssertEqual(review.changedFiles, ["tracked.txt"])
        XCTAssertEqual(fixture.fs.sourceBytes, source); XCTAssertEqual(fixture.git.sourceHead, snapshot.sourceHEAD)
        XCTAssertEqual(stages, [.twinCommitWillAdvance, .twinCommitAdvanced, .twinIndexWritten])
        let updates = fixture.git.calls.filter { $0.command.first == "update-ref" }
        XCTAssertEqual(updates.map { $0.command[1] }, [snapshot.twinBranch])
        XCTAssertTrue(fixture.git.calls.allSatisfy { $0.arguments.contains("core.hooksPath=/dev/null") && $0.arguments.contains("commit.gpgsign=false") })
    }
    func testReviewNeverTreatsUncommittedBytesOrWrongAncestryAsApprovedOutput() throws {
        let fixture = TwinGitFixture(), snapshot = try fixture.snapshot()
        fixture.fs.file(snapshot.worktreePath + "/new.txt", Data("not committed".utf8))
        XCTAssertFalse(try fixture.service.review(snapshot: snapshot).clean)
        fixture.git.ancestor = false
        XCTAssertThrowsError(try fixture.service.review(snapshot: snapshot))
    }
    func testMergeCallbackRunsAfterPreflightAndContainsOnlyApprovedMutationCommands() throws {
        let fixture = TwinGitFixture(), snapshot = try fixture.snapshot()
        fixture.fs.file(snapshot.worktreePath + "/tracked.txt", Data("review fix\n".utf8))
        let review = try fixture.service.commit(snapshot: snapshot, message: "Fix")
        var entered = false, stages: [TwinGitMutationStage] = []
        fixture.git.observe = { call in
            if ["update-ref", "merge"].contains(call.command.first ?? "") || call.command.first == "read-tree" && call.environment["GIT_INDEX_FILE"] == nil { XCTAssertTrue(entered) }
            if !entered { XCTAssertNotEqual(call.command.first, "merge") }
            else { XCTAssertFalse(["hash-object", "write-tree"].contains(call.command.first ?? "")) }
        }
        let result = try fixture.service.merge(snapshot: snapshot, tip: review.tip, committing: { mutation in entered = true; defer { entered = false }; return try mutation() }, recordMutation: { stages.append($0) })
        XCTAssertEqual(result, .merged(commit: fixture.git.sourceHead))
        XCTAssertEqual(stages, [.sourceCheckpointWillAdvance, .sourceCheckpointAdvanced, .sourceIndexWritten, .mergeWillStart, .mergeCompleted])
        XCTAssertFalse(fixture.git.calls.contains { $0.command.first == "reset" || $0.command.first == "stash" || $0.command.contains("--force") || $0.command.first == "read-tree" && $0.command.contains("-u") })
    }
    func testChangedSourceIndexHeadAndWorkingTreeHoldMergeWithoutMutations() throws {
        for change in ["index", "head", "files"] {
            let fixture = TwinGitFixture(), snapshot = try fixture.snapshot()
            switch change {
            case "index": fixture.fs.file("/source/.git/index", Data("new staged input".utf8))
            case "head": fixture.git.sourceHead = String(repeating: "b", count: 40)
            default: fixture.fs.file("/source/tracked.txt", Data("new source work".utf8))
            }
            let before = fixture.git.calls.count
            let result = try fixture.service.merge(snapshot: snapshot, tip: snapshot.snapshotCommit, committing: { try $0() })
            guard case .held = result else { return XCTFail("Expected source hold: \(change)") }
            XCTAssertFalse(fixture.git.calls.dropFirst(before).contains { ["update-ref", "merge"].contains($0.command.first ?? "") })
        }
    }
    func testSourceInventoryRechecksLeafPathSetAndParentsAtFinalAdmission() throws {
        for change in ["write", "add", "remove", "restore", "inode", "parent", "delete-tracked"] {
            let f = TwinGitFixture(), snapshot = try f.snapshot(), original = f.fs.sourceBytes
            let before = f.git.calls.count
            let result = try f.service.merge(snapshot: snapshot, tip: snapshot.snapshotCommit, committing: { mutation in
                switch change {
                case "write": f.fs.file("/source/tracked.txt", Data("editor write".utf8))
                case "add": f.fs.file("/source/new-input", Data("new untracked input".utf8))
                case "remove": f.fs.files.removeValue(forKey: "/source/new 한글\nfile.bin")
                case "restore": f.fs.file("/source/deleted.txt", Data("restored".utf8))
                case "inode": f.fs.inodes["/source/tracked.txt"] = 999
                case "parent": f.fs.directories["/source"] = 999
                default: f.git.sourcePaths = (Array(f.fs.entries("/source").keys) + ["deleted.txt"]).sorted(); f.fs.files.removeValue(forKey: "/source/tracked.txt")
                }
                return try mutation()
            })
            guard case .held = result else { return XCTFail("Source changed after preflight: " + change) }
            XCTAssertFalse(f.git.calls.dropFirst(before).contains { ["update-ref", "merge"].contains($0.command.first ?? "") || $0.command.first == "read-tree" && $0.environment["GIT_INDEX_FILE"] == nil }, change)
            XCTAssertEqual(f.git.sourceHead, snapshot.sourceHEAD)
            XCTAssertEqual(f.fs.files["/source/.git/index"], original["/source/.git/index"])
        }
    }
    func testFinalMergeRejectsReviewedTwinRefThatAdvancedDuringAdmission() throws {
        let f = TwinGitFixture(), snapshot = try f.snapshot(); let before = f.git.calls.count
        let result = try f.service.merge(snapshot: snapshot, tip: snapshot.snapshotCommit, committing: { mutation in
            f.git.twinHead = String(repeating: "d", count: 40); return try mutation()
        })
        guard case .held = result else { return XCTFail("The approved twin tip changed") }
        XCTAssertFalse(f.git.calls.dropFirst(before).contains { ["update-ref", "merge"].contains($0.command.first ?? "") })
    }
    func testTrustedCommitRejectsFinalHeadOrIndexReplacement() throws {
        for name in ["HEAD", "index"] {
            let f = TwinGitFixture(), snapshot = try f.snapshot(); f.fs.file(snapshot.worktreePath + "/tracked.txt", Data("fix".utf8))
            let before = f.git.calls.count
            XCTAssertThrowsError(try f.service.commit(snapshot: snapshot, message: "fix", recordMutation: { stage in
                if stage == .twinCommitWillAdvance { f.fs.file(snapshot.ownership.adminDirectory + "/" + name, Data("changed".utf8)) }
            }))
            XCTAssertEqual(f.git.twinHead, snapshot.snapshotCommit)
            XCTAssertFalse(f.git.calls.dropFirst(before).contains { $0.command.first == "update-ref" })
        }
    }
    func testFinalMergePolicyRejectsEffectiveConfigIncludesAndAttributes() throws {
        for change in ["driver", "include", "union"] {
            let f = TwinGitFixture(), snapshot = try f.snapshot(); let before = f.git.calls.count
            let result = try f.service.merge(snapshot: snapshot, tip: snapshot.snapshotCommit, committing: { mutation in f.git.unsafe = change; return try mutation() })
            guard case .held = result else { return XCTFail("Unsafe final policy: " + change) }
            XCTAssertFalse(f.git.calls.dropFirst(before).contains { ["update-ref", "merge"].contains($0.command.first ?? "") || $0.command.first == "read-tree" && $0.environment["GIT_INDEX_FILE"] == nil })
        }
    }
    func testTrustedCommitRechecksPolicyAfterDurableJournalBeforeRefAdvance() throws {
        for change in ["driver", "include", "union"] {
            let f = TwinGitFixture(), snapshot = try f.snapshot()
            f.fs.file(snapshot.worktreePath + "/tracked.txt", Data("review fix".utf8)); let before = f.git.calls.count
            XCTAssertThrowsError(try f.service.commit(snapshot: snapshot, message: "fix", recordMutation: { if $0 == .twinCommitWillAdvance { f.git.unsafe = change } }))
            XCTAssertEqual(f.git.twinHead, snapshot.snapshotCommit)
            XCTAssertFalse(f.git.calls.dropFirst(before).contains { $0.command.first == "update-ref" })
        }
    }
    func testSnapshotRechecksPolicyAfterLastBaselineIndexReadBeforeCheckout() throws {
        for change in ["driver", "include", "union"] {
            let f = TwinGitFixture(); var indexReads = 0
            f.fs.onRead = { path in
                if path == "/source/.git/index", f.fs.files.keys.contains(where: { $0.hasSuffix("/snapshot-plan.json") }) {
                    indexReads += 1; if indexReads == 2 { f.git.unsafe = change }
                }
            }
            XCTAssertThrowsError(try f.snapshot())
            XCTAssertFalse(f.git.calls.contains { $0.command.first == "worktree" && $0.command.contains("add") })
        }
    }
    func testRejectedFinalAdmissionPreventsEverySourceMutation() throws {
        let fixture = TwinGitFixture(), snapshot = try fixture.snapshot(); enum Admission: Error { case changed }
        let before = fixture.git.calls.count
        let result = try fixture.service.merge(snapshot: snapshot, tip: snapshot.snapshotCommit, committing: { _ in throw Admission.changed })
        guard case .held = result else { return XCTFail("Admission must hold before any mutation") }
        XCTAssertFalse(fixture.git.calls.dropFirst(before).contains { $0.command.first == "update-ref" || $0.command.first == "merge" })
    }
    func testConflictAndInterruptedCheckpointArePreservedForHumanResolution() throws {
        let fixture = TwinGitFixture(), snapshot = try fixture.snapshot(); fixture.git.mergeConflict = true
        let result = try fixture.service.merge(snapshot: snapshot, tip: snapshot.snapshotCommit, committing: { try $0() })
        guard case .conflict(let paths, _) = result else { return XCTFail("Expected preserved conflict") }
        XCTAssertEqual(paths, ["tracked.txt"])
        XCTAssertTrue(fixture.fs.files["/source/.git/MERGE_HEAD"] != nil)
        XCTAssertFalse(fixture.git.calls.contains { $0.command.first == "reset" || $0.command.contains("--abort") })
        let interrupted = TwinGitFixture(), second = try interrupted.snapshot(); enum Journal: Error { case unavailable }
        let uncertain = try interrupted.service.merge(snapshot: second, tip: second.snapshotCommit, committing: { try $0() }, recordMutation: { if $0 == .sourceCheckpointAdvanced { throw Journal.unavailable } })
        guard case .needsReview = uncertain else { return XCTFail("Checkpoint ambiguity must require review") }
        XCTAssertEqual(interrupted.git.sourceHead, second.snapshotCommit)
        XCTAssertFalse(interrupted.git.calls.contains { $0.command.first == "merge" })
    }
    func testCleanupFinalAdmissionCanRefuseBeforeAnyMutation() throws {
        let fixture = TwinGitFixture(), snapshot = try fixture.snapshot()
        enum Admission: Error { case stopped }
        XCTAssertThrowsError(try fixture.service.cleanup(snapshot: snapshot, expectedTip: snapshot.snapshotCommit,
            committing: { _ in throw Admission.stopped }))
        XCTAssertTrue(fixture.inspector.removed.isEmpty)
        XCTAssertEqual(fixture.git.twinHead, snapshot.snapshotCommit)
        XCTAssertFalse(fixture.git.calls.contains { $0.command.first == "update-ref" && $0.command.contains("-d") })
    }
    func testCleanupFinalAdmissionWrapsRemovalCASAndDurableStages() throws {
        let fixture = TwinGitFixture(), snapshot = try fixture.snapshot()
        var admitted = false, calls = 0, stages: [TwinGitMutationStage] = []
        try fixture.service.cleanup(snapshot: snapshot, expectedTip: snapshot.snapshotCommit, committing: { mutation in
            calls += 1; admitted = true; defer { admitted = false }
            XCTAssertTrue(fixture.inspector.removed.isEmpty)
            try mutation()
            XCTAssertNil(fixture.git.twinHead)
            XCTAssertEqual(fixture.inspector.removed, [snapshot.ownership])
        }, recordMutation: { stage in XCTAssertTrue(admitted); stages.append(stage) })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(stages, [.worktreeWillRemove, .worktreeRemoved, .branchWillDelete, .branchDeleted])
    }
    func testIgnoredOnlyStatusDoesNotInvalidateCommittedReview() throws {
        let f = TwinGitFixture(), snapshot = try f.snapshot()
        f.inspector.ignored = true
        XCTAssertTrue(try f.service.review(snapshot: snapshot).clean)
    }
    func testTrackedIndexDirtyStillInvalidatesReviewWithIgnoredArtifacts() throws {
        let f = TwinGitFixture(), snapshot = try f.snapshot()
        f.inspector.ignored = true; f.git.statusDirty = true
        XCTAssertFalse(try f.service.review(snapshot: snapshot).clean)
    }
    func testCleanupUsesNonforceRemovalAndCASOnlyOwnedBranch() throws {
        let fixture = TwinGitFixture(), snapshot = try fixture.snapshot()
        try fixture.service.cleanup(snapshot: snapshot, expectedTip: snapshot.snapshotCommit)
        XCTAssertEqual(fixture.inspector.removed, [snapshot.ownership])
        let deletions = fixture.git.calls.filter { $0.command.first == "update-ref" && $0.command.contains("-d") }
        XCTAssertEqual(deletions.map(\.command), [["update-ref", "-d", snapshot.twinBranch, snapshot.snapshotCommit]])
        XCTAssertFalse(fixture.git.calls.contains { $0.command.contains("--force") || $0.command.contains("-D") })
        try fixture.service.cleanup(snapshot: snapshot, expectedTip: snapshot.snapshotCommit)
        XCTAssertEqual(fixture.inspector.removed.count, 1)
    }
    func testInterruptedCleanupDoesNotDeclareSuccessWhileGitAdministrationRemains() throws {
        let fixture = TwinGitFixture(), snapshot = try fixture.snapshot()
        fixture.fs.directories.removeValue(forKey: snapshot.worktreePath); fixture.git.twinHead = nil
        XCTAssertThrowsError(try fixture.service.cleanup(snapshot: snapshot, expectedTip: snapshot.snapshotCommit))
        XCTAssertTrue(fixture.inspector.removed.isEmpty)
    }
    func testCleanupRetainsActiveDirtyOrWrongTipArtifacts() throws {
        for reason in ["active", "dirty", "tip"] {
            let fixture = TwinGitFixture(), snapshot = try fixture.snapshot()
            if reason == "active" { fixture.inspector.use = .inUse }
            if reason == "dirty" { fixture.fs.file(snapshot.worktreePath + "/uncommitted", Data("keep".utf8)) }
            let tip = reason == "tip" ? String(repeating: "f", count: 40) : snapshot.snapshotCommit
            XCTAssertThrowsError(try fixture.service.cleanup(snapshot: snapshot, expectedTip: tip))
            XCTAssertTrue(fixture.inspector.removed.isEmpty)
            XCTAssertFalse(fixture.git.calls.contains { $0.command.first == "update-ref" && $0.command.contains("-d") })
        }
    }
    func testSnapshotDiffIsWholeBoundedAndDoesNotInvokeExternalDiff() throws {
        let fixture = TwinGitFixture(), snapshot = try fixture.snapshot()
        XCTAssertEqual(try fixture.service.snapshotDiff(snapshot: snapshot), "snapshot diff\n")
        let diff = try XCTUnwrap(fixture.git.calls.last)
        XCTAssertTrue(diff.command.contains("--no-ext-diff")); XCTAssertTrue(diff.command.contains("--no-textconv"))
        fixture.git.diffTooLarge = true
        XCTAssertThrowsError(try fixture.service.snapshotDiff(snapshot: snapshot))
    }
}

private let twinGitFixtureID = "d53161fb-54d8-4cee-9f02-71f71a1ea675"
private struct TwinGitMemoryEntry: Equatable { var mode: String; var data: Data }
private final class TwinGitFixture {
    let fs = TwinGitMemoryFS(), git: TwinGitMemoryRunner, inspector: TwinGitMemoryInspector
    let service: TwinGitService
    init() {
        git = TwinGitMemoryRunner(fs: fs); inspector = TwinGitMemoryInspector(fs: fs, git: git)
        service = TwinGitService(root: URL(fileURLWithPath: "/runtime"), runner: git, fileSystem: fs, inspector: inspector)
    }
    func snapshot() throws -> TwinGitSnapshot {
        let identity = SupervisorProcessIdentity(pid: 42, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 1)
        let source = TwinSourceBinding(paneID: UUID().uuidString.lowercased(), generation: UUID().uuidString.lowercased(), conversationID: UUID().uuidString.lowercased(), cwd: "/source", configurationRoot: "/profile", provider: .claude, backendPID: 42, providerPID: 43, backendIdentity: identity, providerIdentity: identity)
        return try service.snapshot(source: source, runID: twinGitFixtureID, round: 1)
    }
}
private final class TwinGitMemoryFS: TwinGitFileSystem {
    var files: [String: TwinGitMemoryEntry] = [:], directories: [String: UInt64] = ["/runtime": 100, "/source": 101, "/source/.git": 1]
    var next: UInt64 = 200
    var inodes: [String: UInt64] = [:]
    var onRead: ((String) -> Void)?
    init() { file("/source/.git/index", Data("original staged index".utf8)); file("/source/.git/HEAD", Data("ref: refs/heads/main\n".utf8)); file("/source/tracked.txt", Data("latest working bytes\n".utf8)); file("/source/new 한글\nfile.bin", Data([0, 1, 255, 10])); files["/source/link"] = .init(mode: "120000", data: Data("../external".utf8)); file("/source/ignored.secret", Data("private ignored fixture".utf8)) }
    var sourceBytes: [String: TwinGitMemoryEntry] { files.filter { $0.key.hasPrefix("/source/") && !$0.key.contains("/worktrees/") } }
    func file(_ path: String, _ bytes: Data) { files[path] = .init(mode: "100644", data: bytes) }
    func canonicalPath(_ path: String) throws -> String {
        guard directories[path] != nil || files[path] != nil else { throw TwinGitError.unsafe("Missing fixture path") }; return path
    }
    func info(_ path: String) throws -> TwinGitNode? {
        if let inode = directories[path] { return .init(identity: .init(device: 1, inode: inode), ownerUID: getuid(), kind: .directory, mode: path.hasPrefix("/runtime") ? 0o40700 : 0o40755) }
        guard let value = files[path] else { return nil }
        return .init(identity: .init(device: 1, inode: inodes[path] ?? 9), ownerUID: getuid(), kind: value.mode == "120000" ? .symlink : .regular, mode: value.mode == "120000" ? 0o120777 : 0o100644, size: Int64(value.data.count), modifiedSeconds: Int64(value.data.hashValue))
    }
    func read(_ path: String, limit: Int) throws -> Data { onRead?(path); guard let value = files[path]?.data, value.count <= limit else { throw TwinGitError.unsafe("Missing/large fixture file") }; return value }
    func readLink(_ path: String, limit: Int) throws -> Data { try read(path, limit: limit) }
    func ensurePrivateDirectory(_ path: String) throws { if directories[path] == nil { directories[path] = next; next += 1 } }
    func writePrivate(_ data: Data, path: String) throws { guard files[path] == nil else { throw TwinGitError.unsafe("Existing fixture journal") }; file(path, data) }
    func removePrivateFile(_ path: String) throws { files.removeValue(forKey: path) }
    func entries(_ root: String) -> [String: TwinGitMemoryEntry] {
        var result: [String: TwinGitMemoryEntry] = [:]
        for (path, value) in files where path.hasPrefix(root + "/") {
            let relative = String(path.dropFirst(root.count + 1))
            if relative.hasPrefix(".git/") || relative == ".git" || relative == "ignored.secret" { continue }
            result[relative] = value
        }
        return result
    }
}
private final class TwinGitMemoryRunner: TwinGitCommandRunning {
    var statusDirty = false
    var sourcePaths: [String]?
    struct Call { let arguments, command: [String]; let input: Data?; let environment: [String: String] }
    let fs: TwinGitMemoryFS
    let initialHead = String(repeating: "a", count: 40)
    var sourceHead: String
    var twinHead: String?, twinBranch: String?, twinPath = "", twinAdmin = "/source/.git/worktrees/twin-round-1"
    var trees: [String: [String: TwinGitMemoryEntry]] = [:], commits: [String: String] = [:], objects: [String: Data] = [:], indexes: [String: Data] = [:]
    var calls: [Call] = [], observe: ((Call) -> Void)?, unsafe: String?, ancestor = true, mergeConflict = false, diffTooLarge = false
    init(fs: TwinGitMemoryFS) { self.fs = fs; sourceHead = initialHead }
    func run(arguments: [String], input: Data?, environment: [String: String], timeout: TimeInterval, limit: Int) throws -> WorktreeGitCommandResult {
        let names: Set<String> = ["status", "rev-parse", "symbolic-ref", "config", "ls-files", "check-attr", "hash-object", "read-tree", "update-index", "write-tree", "commit-tree", "worktree", "show-ref", "diff", "merge-base", "update-ref", "merge"]
        guard let index = arguments.firstIndex(where: { names.contains($0) }) else { throw TwinGitError.unsafe("Unknown fixture command") }
        let command = Array(arguments[index...]), cwd = arguments[1], twin = cwd == twinPath && !twinPath.isEmpty
        let call = Call(arguments: arguments, command: command, input: input, environment: environment); calls.append(call); observe?(call)
        func text(_ value: String) -> WorktreeGitCommandResult { .init(status: 0, stdout: Data((value + "\n").utf8)) }
        func bytes(_ value: Data) -> WorktreeGitCommandResult { .init(status: 0, stdout: value) }
        switch command[0] {
        case "rev-parse":
            if command.contains("--show-toplevel") { return text(twin ? twinPath : "/source") }
            if command.contains("--absolute-git-dir") { return text(twin ? twinAdmin : "/source/.git") }
            if command.contains("--git-common-dir") { return text("/source/.git") }
            if command.contains("--git-path") { return text((twin ? twinAdmin : "/source/.git") + "/index") }
            if command.last?.hasPrefix("refs/heads/trano/twins/") == true { return text(twinHead!) }
            if command.last?.hasSuffix("^{commit}") == true, command.last?.hasPrefix("refs/heads/trano/twins/") == true { return text(twinHead!) }
            if command.last?.hasSuffix("^{tree}") == true { let oid = String(command.last!.dropLast(7)); return text(commits[oid] ?? String(repeating: "c", count: 40)) }
            return text(twin ? twinHead! : sourceHead)
        case "symbolic-ref": return text(twin ? twinBranch! : "refs/heads/main")
        case "config":
            if unsafe == "filter" || unsafe == "driver" || unsafe == "include", command.contains("--name-only") { return bytes(Data((unsafe == "filter" ? "filter.bad.process\0" : "merge.bad.driver\0").utf8)) }
            if unsafe == "sparse", command.contains("--type=bool") { return text("core.sparsecheckout true") }
            return .init(status: 1)
        case "status": return bytes(statusDirty ? Data("M  tracked.txt\0".utf8) : Data())
        case "ls-files":
            if command.contains("--ignored") { return bytes(Data()) }
            if command.contains("-v") { return bytes(Data((unsafe == "hidden" ? "S tracked.txt\0" : "H tracked.txt\0").utf8)) }
            if command.contains("--stage") { return bytes(Data(((unsafe == "submodule" ? "160000 " : "100644 ") + initialHead + " 0\ttracked.txt\0").utf8)) }
            if command.contains("--unmerged") { return bytes(mergeConflict ? Data(("100644 " + initialHead + " 1\ttracked.txt\0").utf8) : Data()) }
            if !twin, let sourcePaths { return bytes(Data((sourcePaths.joined(separator: "\0") + "\0").utf8)) }
            var paths = Set(fs.entries(cwd).keys); if !twin { paths.insert("deleted.txt") }; return bytes(Data((paths.sorted().joined(separator: "\0") + "\0").utf8))
        case "check-attr":
            let paths = input!.split(separator: 0); var result = Data()
            for path in paths { result.append(contentsOf: path); result.append(0); result.append(Data("merge\0".utf8)); result.append(Data((unsafe == "union" ? "union\0" : "unspecified\0").utf8)) }
            return bytes(result)
        case "hash-object": let value = input!; let oid = Self.hash(Data("blob\(value.count)\0".utf8) + value); objects[oid] = value; return text(oid)
        case "read-tree":
            if let key = environment["GIT_INDEX_FILE"] { indexes[key] = Data(); fs.file(key, Data("private index".utf8)) }
            else { fs.file((twin ? twinAdmin : "/source/.git") + "/index", Data(("index-" + command[1]).utf8)) }
            return bytes(Data())
        case "update-index": indexes[environment["GIT_INDEX_FILE"]!] = input!; return bytes(Data())
        case "write-tree":
            let payload = indexes[environment["GIT_INDEX_FILE"]!]!; let oid = Self.hash(payload); var entries: [String: TwinGitMemoryEntry] = [:]
            for record in payload.split(separator: 0) {
                let tab = record.firstIndex(of: 9)!; let meta = String(decoding: record[..<tab], as: UTF8.self).split(separator: " "); let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
                entries[path] = .init(mode: String(meta[0]), data: objects[String(meta[1])]!)
            }
            trees[oid] = entries; return text(oid)
        case "commit-tree": let oid = Self.hash(Data(command.joined(separator: " ").utf8) + (input ?? Data())); commits[oid] = command[1]; return text(oid)
        case "show-ref": if command.last == "refs/heads/main" { return bytes(Data()) }; if twinHead != nil, command.last == twinBranch { return bytes(Data()) }; return .init(status: 1)
        case "worktree":
            if command.contains("list") {
                var output = "worktree /source\0HEAD " + sourceHead + "\0branch refs/heads/main\0\0"
                if unsafe == "shared" { output += "worktree /other\0HEAD " + sourceHead + "\0branch refs/heads/main\0\0" }
                if let twinHead, let twinBranch { output += "worktree " + twinPath + "\0HEAD " + twinHead + "\0branch " + twinBranch + "\0\0" }
                return bytes(Data(output.utf8))
            }
            let delimiter = command.firstIndex(of: "--")!; twinPath = command[delimiter + 1]; twinHead = command[delimiter + 2]; twinBranch = "refs/heads/" + command[command.firstIndex(of: "-b")! + 1]
            fs.directories[twinPath] = 20; fs.directories[twinAdmin] = 21
            fs.file(twinPath + "/.git", Data(("gitdir: " + twinAdmin + "\n").utf8)); fs.file(twinAdmin + "/index", Data("twin index".utf8)); fs.file(twinAdmin + "/HEAD", Data(("ref: " + twinBranch! + "\n").utf8))
            for (path, value) in trees[commits[twinHead!]!]! { fs.files[twinPath + "/" + path] = value }
            return bytes(Data())
        case "diff":
            if command.contains("--name-only") {
                let a = trees[commits[command[command.count - 3]] ?? ""] ?? [:], b = trees[commits[command[command.count - 2]] ?? ""] ?? [:]
                let paths = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted(); return bytes(paths.isEmpty ? Data() : Data((paths.joined(separator: "\0") + "\0").utf8))
            }
            return bytes(diffTooLarge ? Data(repeating: 1, count: limit + 1) : Data("snapshot diff\n".utf8))
        case "merge-base": return .init(status: ancestor ? 0 : 1)
        case "update-ref":
            if command[1] == "-d" { guard twinHead == command[3] else { return .init(status: 1) }; twinHead = nil; return bytes(Data()) }
            if command[1] == "refs/heads/main" { guard sourceHead == command[3] else { return .init(status: 1) }; sourceHead = command[2] }
            else { guard twinHead == command[3] else { return .init(status: 1) }; twinHead = command[2] }
            return bytes(Data())
        case "merge":
            if mergeConflict { fs.file("/source/.git/MERGE_HEAD", Data((twinHead! + "\n").utf8)); return .init(status: 1) }
            sourceHead = Self.hash(Data("merge".utf8) + Data(command.last!.utf8)); return bytes(Data())
        default: throw TwinGitError.unsafe("Unhandled fixture command")
        }
    }
    static func hash(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
private final class TwinGitMemoryInspector: WorktreeGitInspecting {
    let fs: TwinGitMemoryFS, git: TwinGitMemoryRunner
    var removed: [WorktreeIdentity] = [], use = WorktreeProcessUse.unused
    var ignored = false
    init(fs: TwinGitMemoryFS, git: TwinGitMemoryRunner) { self.fs = fs; self.git = git }
    var identity: WorktreeIdentity { .init(path: git.twinPath, commonDirectory: "/source/.git", adminDirectory: git.twinAdmin, pathIdentity: .init(device: 1, inode: 20), gitFileIdentity: .init(device: 1, inode: 9), adminIdentity: .init(device: 1, inode: 21), commonIdentity: .init(device: 1, inode: 1)) }
    var entry: WorktreeSnapshotEntry { .init(path: git.twinPath, head: git.twinHead, branch: git.twinBranch, identity: identity) }
    func creationInvocation(cwd: String, gitArguments: [String]) throws -> WorktreeCreationInvocation? { nil }
    func snapshot(cwd: String, gitArguments: [String]) throws -> WorktreeRepositorySnapshot { .init(commonDirectory: "/source/.git", commonIdentity: .init(device: 1, inode: 1), worktrees: [entry]) }
    func inspect(_ identity: WorktreeIdentity) throws -> WorktreeInspection {
        guard identity == self.identity else { throw TwinGitError.unsafe("TwinGitFixture ownership changed") }
        let committed = git.trees[git.commits[git.twinHead ?? ""] ?? ""] ?? [:]
        return .init(entry: entry, clean: !ignored && fs.entries(git.twinPath) == committed, hasIgnored: ignored, operationInProgress: false, retainedHEAD: true)
    }
    func remove(_ identity: WorktreeIdentity) throws {
        removed.append(identity); fs.directories.removeValue(forKey: identity.path); fs.directories.removeValue(forKey: identity.adminDirectory)
        fs.files = fs.files.filter { !$0.key.hasPrefix(identity.path + "/") && !$0.key.hasPrefix(identity.adminDirectory + "/") }
    }
    func processUse(path: String) throws -> WorktreeProcessUse { use }
}

final class PessimisticTwinNativeFileTests: XCTestCase {
    // Implements: FR-TWIN-2, FR-TWIN-4, FR-TWIN-9
    func testNativeReadRejectsParentSymlinkAndPreservesRawLeafSymlink() throws {
        let parent = try TwinNativeGitFileSystem().canonicalPath(FileManager.default.temporaryDirectory.path)
        let root = URL(fileURLWithPath: parent).appendingPathComponent("twin-native-unit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let outside = root.appendingPathComponent("outside"), workspace = root.appendingPathComponent("workspace")
        for path in [outside, workspace] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try Data([0, 255, 10]).write(to: outside.appendingPathComponent("data"))
        try FileManager.default.createSymbolicLink(atPath: workspace.appendingPathComponent("parent").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: workspace.appendingPathComponent("leaf").path, withDestinationPath: "../outside/data")
        let fs = TwinNativeGitFileSystem()
        XCTAssertThrowsError(try fs.read(workspace.appendingPathComponent("parent/data").path, limit: 32))
        XCTAssertThrowsError(try fs.info(workspace.appendingPathComponent("parent/data").path))
        XCTAssertEqual(try fs.readLink(workspace.appendingPathComponent("leaf").path, limit: 128), Data("../outside/data".utf8))
        XCTAssertEqual(try fs.read(outside.appendingPathComponent("data").path, limit: 32), Data([0, 255, 10]))
    }
}
