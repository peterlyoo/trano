import XCTest
@testable import TerminalCore

final class WorktreeGitTests: XCTestCase {
    // Implements: FR-WT-1, FR-WT-3, FR-WT-4, FR-WT-6
    func testThrowingFinalCallbackPreventsEveryMutatingGitCommand() throws {
        enum CommitAbort: Error { case changed }
        let fixture = Fixture()
        var called = 0
        XCTAssertThrowsError(try fixture.inspector.remove(fixture.identity, beforeRemoval: {
            called += 1
            throw CommitAbort.changed
        })) { error in XCTAssertTrue(error is CommitAbort) }
        XCTAssertEqual(called, 1)
        XCTAssertFalse(fixture.runner.calls.contains { $0.contains("remove") })
    }
    func testFinalCallbackRunsAfterAllChecksImmediatelyBeforeRemoval() throws {
        let fixture = Fixture()
        var events: [String] = [], observations = -1
        fixture.runner.mutate = { arguments in
            if arguments.contains("remove") {
                events.append("remove")
                XCTAssertEqual(fixture.fs.observations, observations)
                XCTAssertEqual(fixture.process.calls, 2)
            }
        }
        try fixture.inspector.remove(fixture.identity, beforeRemoval: {
            XCTAssertEqual(fixture.process.calls, 2)
            XCTAssertTrue(fixture.runner.calls.filter { $0.contains("status") }.count >= 2)
            observations = fixture.fs.observations
            events.append("callback")
        })
        XCTAssertEqual(events, ["callback", "remove"])
    }
    func testCommittingBoundaryContainsOnlyTheFinalMutation() throws {
        let fixture = Fixture()
        var inside = false, mutations = 0
        fixture.runner.mutate = { arguments in
            if arguments.contains("remove") { XCTAssertTrue(inside); mutations += 1 }
            else { XCTAssertFalse(inside) }
        }
        try fixture.inspector.remove(fixture.identity, committing: { mutation in
            XCTAssertEqual(fixture.process.calls, 2)
            inside = true; defer { inside = false }
            try mutation()
        })
        XCTAssertEqual(mutations, 1)
    }
    func testCleanOrProcessFiltersAreHeldBeforeStatusWithoutReadingValues() throws {
        for keys in ["filter.example.clean\0", "filter.example.process\0"] {
            let fixture = Fixture(); fixture.runner.filterKeys = Data(keys.utf8)
            XCTAssertThrowsError(try fixture.inspector.inspect(fixture.identity))
            XCTAssertThrowsError(try fixture.inspector.remove(fixture.identity))
            XCTAssertFalse(fixture.runner.calls.contains { $0.contains("status") || $0.contains("remove") })
            XCTAssertTrue(fixture.runner.calls.filter { $0.contains("config") }.allSatisfy { $0.contains("--name-only") })
        }
    }
    func testFilterQueryFailureCannotReachStatus() throws {
        let fixture = Fixture(); fixture.runner.filterStatus = 2
        XCTAssertThrowsError(try fixture.inspector.inspect(fixture.identity))
        XCTAssertFalse(fixture.runner.calls.contains { $0.contains("status") || $0.contains("remove") })
    }
    func testStatusEmptyCannotAuthorizeAssumeUnchangedOrSkipWorktree() throws {
        for flags in ["h tracked\0", "S tracked\0", "s tracked\0", "m tracked\0", "? tracked\0", "X tracked\0"] {
            let fixture = Fixture(); fixture.runner.index = Data(flags.utf8)
            XCTAssertThrowsError(try fixture.inspector.inspect(fixture.identity))
            XCTAssertThrowsError(try fixture.inspector.remove(fixture.identity))
            XCTAssertFalse(fixture.runner.calls.contains { $0.contains("remove") })
        }
    }
    func testSparseIndexOrCheckoutConfigurationCannotAuthorizeRemoval() throws {
        for config in ["core.sparsecheckout true\n", "core.sparsecheckoutcone true\n", "index.sparse true\n", "core.sparsecheckout maybe\n"] {
            let fixture = Fixture(); fixture.runner.sparseConfig = config
            XCTAssertThrowsError(try fixture.inspector.inspect(fixture.identity))
            XCTAssertThrowsError(try fixture.inspector.remove(fixture.identity))
            XCTAssertFalse(fixture.runner.calls.contains { $0.contains("remove") })
        }
    }
    func testMalformedOrTruncatedIndexFlagsFailClosed() throws {
        for flags in ["H tracked", "H \0", "HH tracked\0", "H tracked\0\0", "\0"] {
            let fixture = Fixture(); fixture.runner.index = Data(flags.utf8)
            XCTAssertThrowsError(try fixture.inspector.inspect(fixture.identity))
        }
    }
    func testOrdinaryIndexEntriesAndExplicitSparseFalseStayEligible() throws {
        let fixture = Fixture()
        fixture.runner.index = Data("H 한 글\nline\0H -literal\0".utf8)
        fixture.runner.sparseConfig = "core.sparsecheckout false\ncore.sparsecheckoutcone false\nindex.sparse false\n"
        XCTAssertTrue(try fixture.inspector.inspect(fixture.identity).clean)
        XCTAssertTrue(fixture.runner.calls.contains { Array($0.suffix(4)) == ["ls-files", "-v", "-z", "--"] })
        XCTAssertFalse(fixture.runner.calls.contains { $0.contains("update-index") })
    }
    func testNativeFilesystemReadsBoundedRegularDataAndRefusesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("worktree-file-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("한 글.txt")
        try Data("hello\n".utf8).write(to: file)
        let link = root.appendingPathComponent("pointer")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)
        let fs = WorktreeNativeGitFileSystem()
        XCTAssertEqual(try fs.info(file.path)?.kind, .regular)
        XCTAssertEqual(try fs.info(link.path)?.kind, .symlink)
        XCTAssertEqual(try fs.read(file.path, limit: 6), Data("hello\n".utf8))
        XCTAssertThrowsError(try fs.read(file.path, limit: 5))
        XCTAssertThrowsError(try fs.read(link.path, limit: 100))
        XCTAssertEqual(Set(try fs.children(root.path, limit: 2)), ["한 글.txt", "pointer"])
        XCTAssertThrowsError(try fs.children(root.path, limit: 1))
        XCTAssertThrowsError(try fs.children(link.path, limit: 2))
    }
    func testPorcelainSupportsLiteralNewlineAndUnicodePaths() throws {
        let fixture = Fixture(), path = "/work/한 글\nline"
        fixture.fs.directory(path, 5)
        fixture.fs.file(path + "/.git", 6, "gitdir: /repo/.git/worktrees/topic\n")
        fixture.fs.file("/repo/.git/worktrees/topic/gitdir", 10, path + "/.git\n")
        fixture.runner.list = fixture.runner.list.replacingOccurrences(of: "worktree /work/topic\0", with: "worktree " + path + "\0")
        let snapshot = try fixture.inspector.snapshot(cwd: "/repo", gitArguments: ["worktree", "add", "--", path])
        XCTAssertEqual(snapshot.worktrees.last?.path, path)
        XCTAssertEqual(snapshot.worktrees.last?.identity?.path, path)
    }
    func testHEADCanAdvanceSinceCreationWhenCurrentHEADRemainsRetained() throws {
        let fixture = Fixture(), newer = String(repeating: "c", count: 40)
        fixture.runner.list = fixture.runner.list.replacingOccurrences(of: String(repeating: "b", count: 40), with: newer)
        fixture.runner.verifiedHEAD = newer
        let inspection = try fixture.inspector.inspect(fixture.identity)
        XCTAssertEqual(inspection.entry.head, newer)
        XCTAssertTrue(inspection.retainedHEAD)
        fixture.runner.verifiedHEAD = String(repeating: "d", count: 40)
        XCTAssertThrowsError(try fixture.inspector.inspect(fixture.identity))
    }
    func testDetachedHEADNeedsPersistentBranchTagOrRemoteRetention() throws {
        for ref in ["refs/heads/keep", "refs/tags/keep", "refs/remotes/origin/keep"] {
            let fixture = Fixture()
            fixture.runner.list = fixture.runner.list.replacingOccurrences(of: "branch refs/heads/topic\0", with: "detached\0")
            fixture.runner.refs = ref + "\n"
            XCTAssertTrue(try fixture.inspector.inspect(fixture.identity).retainedHEAD)
        }
    }
    func testReplacementOfGitFileAdminOrCommonIsRejected() throws {
        for path in ["/work/topic/.git", "/repo/.git/worktrees/topic", "/repo/.git"] {
            let fixture = Fixture(), info = fixtureInfo(path)
            fixture.fs.nodes[path] = .init(identity: .init(device: 1, inode: 999), ownerUID: 501, kind: info)
            XCTAssertThrowsError(try fixture.inspector.inspect(fixture.identity))
        }
    }
    private func fixtureInfo(_ path: String) -> WorktreeGitFileKind { path == "/work/topic/.git" ? .regular : .directory }
    func testBoundsInvalidUTF8AndTraversalMetadataFailClosed() throws {
        let fixture = Fixture()
        XCTAssertNil(try fixture.inspector.creationInvocation(cwd: "/repo", gitArguments: Array(repeating: "worktree", count: 513)))
        fixture.runner.list = String(repeating: "a", count: 1_048_577)
        XCTAssertThrowsError(try fixture.inspector.snapshot(cwd: "/repo", gitArguments: ["worktree", "add", "../work/topic"]))
        let processFixture = Fixture()
        processFixture.process.value = .init(records: [.init(pid: 10, ownerUID: 501, cwd: "/repo"), .init(pid: 10, ownerUID: 501, cwd: "/repo")], complete: true)
        XCTAssertEqual(try processFixture.inspector.processUse(path: "/work/topic"), .uncertain)
    }
    func testBareCapturesDirectoryAtOptionPositionBeforeLaterC() throws {
        let fixture = Fixture()
        let value = try fixture.inspector.creationInvocation(cwd: "/repo", gitArguments: ["--bare", "-C", "../work", "worktree", "add", "topic"])
        XCTAssertEqual(value?.cwd, "/work")
        XCTAssertEqual(value?.gitArguments, ["--git-dir=/repo", "--bare", "worktree", "add", "--", "/work/topic"])
    }
    func testAttachedCIsUnsupportedByGitAndNotCaptured() throws {
        let fixture = Fixture()
        XCTAssertNil(try fixture.inspector.creationInvocation(cwd: "/repo", gitArguments: ["-C../work", "worktree", "add", "topic"]))
    }
    func testSymlinkBeforeDotDotCannotBeHiddenByNormalization() throws {
        let fixture = Fixture()
        fixture.fs.nodes["/repo/link"] = .init(identity: .init(device: 1, inode: 99), ownerUID: 501, kind: .symlink)
        XCTAssertThrowsError(try fixture.inspector.creationInvocation(cwd: "/repo", gitArguments: ["-C", "link/../..", "worktree", "add", "topic"]))
        fixture.fs.nodes["/repo/.git/worktrees/link"] = .init(identity: .init(device: 1, inode: 100), ownerUID: 501, kind: .symlink)
        fixture.fs.file("/work/topic/.git", 6, "gitdir: /repo/.git/worktrees/link/../topic\n")
        let value = try fixture.inspector.snapshot(cwd: "/repo", gitArguments: ["worktree", "add", "../work/topic"])
        XCTAssertNil(value.worktrees.last?.identity)
    }
    func testReflogTransactionLocksBlockRemoval() throws {
        let fixture = Fixture()
        fixture.fs.directory("/repo/.git/logs", 104)
        fixture.fs.file("/repo/.git/logs/HEAD.lock", 105, "")
        XCTAssertTrue(try fixture.inspector.inspect(fixture.identity).operationInProgress)
        XCTAssertThrowsError(try fixture.inspector.remove(fixture.identity))
    }
    func testObjectMetadataLocksBlockRemoval() throws {
        let fixture = Fixture()
        fixture.fs.directory("/repo/.git/objects", 101)
        fixture.fs.directory("/repo/.git/objects/pack", 102)
        fixture.fs.file("/repo/.git/objects/pack/multi-pack-index.lock", 103, "")
        XCTAssertTrue(try fixture.inspector.inspect(fixture.identity).operationInProgress)
        XCTAssertThrowsError(try fixture.inspector.remove(fixture.identity))
    }
    func testCreationRejectsConfigNamespaceUnknownAndNonAddCommands() throws {
        let fixture = Fixture()
        for args in [["-c", "http.extraHeader=secret", "worktree", "add", "topic"], ["--namespace=private", "worktree", "add", "topic"], ["--unknown", "worktree", "add", "topic"], ["worktree", "remove", "topic"], ["worktree", "add", "--unknown", "topic"], ["worktree", "add", "topic", "HEAD", "extra"]] {
            XCTAssertNil(try fixture.inspector.creationInvocation(cwd: "/repo", gitArguments: args))
        }
        XCTAssertTrue(fixture.runner.calls.isEmpty)
    }
    func testCreationHonorsDoubleDashHyphenPathAndUnicode() throws {
        let fixture = Fixture()
        let invocation = try fixture.inspector.creationInvocation(cwd: "/work", gitArguments: ["worktree", "add", "--", "-한 글;'"])
        XCTAssertEqual(invocation?.targetPath, "/work/-한 글;'")
        XCTAssertEqual(invocation?.gitArguments, ["worktree", "add", "--", "/work/-한 글;'"])
    }
    func testSnapshotPreservesFinalRelativeGitDirSemanticsAndSafeEnvironment() throws {
        let fixture = Fixture()
        _ = try fixture.inspector.snapshot(cwd: "/repo", gitArguments: ["--git-dir=../repo/.git", "-C", "../work", "worktree", "add", "topic"])
        XCTAssertTrue(fixture.runner.calls[0].contains("--git-dir=/repo/.git"))
        XCTAssertEqual(fixture.runner.calls[0].prefix(2), ["-C", "/work"])
        XCTAssertTrue(fixture.runner.calls.allSatisfy { $0.contains("core.fsmonitor=false") && $0.contains("core.hooksPath=/dev/null") })
        XCTAssertTrue(fixture.runner.environments.allSatisfy { $0["GIT_NO_LAZY_FETCH"] == "1" })
        XCTAssertTrue(fixture.runner.environments.allSatisfy { $0["GIT_CONFIG_NOSYSTEM"] == "1" && $0["GIT_CONFIG_GLOBAL"] == "/dev/null" && $0["GIT_CONFIG_COUNT"] == nil && $0["GIT_DIR"] == nil })
    }
    func testMalformedDuplicateAndTruncatedPorcelainFailClosed() throws {
        for list in ["worktree /repo\0HEAD nope\0\0", "worktree /repo\0bare\0\0worktree /repo\0bare\0\0", "worktree /repo\0bare\0", "worktree /repo\0unknown value\0\0"] {
            let fixture = Fixture(); fixture.runner.list = list
            XCTAssertThrowsError(try fixture.inspector.snapshot(cwd: "/repo", gitArguments: ["worktree", "add", "../work/topic"]))
        }
    }
    func testMainLockedBareAndPrunableNeverGainLinkedIdentity() throws {
        for flag in ["locked reason", "prunable reason", "bare"] {
            let fixture = Fixture()
            let marker = "branch refs/heads/topic\0\0"
            fixture.runner.list = fixture.runner.list.replacingOccurrences(of: marker, with: "branch refs/heads/topic\0" + flag + "\0\0")
            let snapshot = try fixture.inspector.snapshot(cwd: "/repo", gitArguments: ["worktree", "add", "../work/topic"])
            XCTAssertNil(snapshot.worktrees.last?.identity)
        }
    }
    func testIdentityReplacementAndPointerMismatchAreRejected() throws {
        for change in 0..<4 {
            let fixture = Fixture()
            switch change {
            case 0: fixture.fs.directory("/work/topic", 999)
            case 1: fixture.fs.file("/work/topic/.git", 6, "gitdir: /repo/.git\n")
            case 2: fixture.fs.file("/repo/.git/worktrees/topic/gitdir", 10, "/work/other/.git\n")
            default: fixture.fs.file("/repo/.git/worktrees/topic/commondir", 7, "/other\n")
            }
            XCTAssertThrowsError(try fixture.inspector.inspect(fixture.identity))
        }
    }
    func testSymlinkAndForeignOwnedMetadataAreNotCaptured() throws {
        for kind in [WorktreeGitFileKind.symlink, .regular] {
            let fixture = Fixture()
            fixture.fs.nodes["/work/topic/.git"] = .init(identity: .init(device: 1, inode: 6), ownerUID: kind == .regular ? 502 : 501, kind: kind)
            let snapshot = try fixture.inspector.snapshot(cwd: "/repo", gitArguments: ["worktree", "add", "../work/topic"])
            XCTAssertNil(snapshot.worktrees.last?.identity)
        }
    }
    func testTrackedUntrackedIgnoredAndRenameEntriesBlockRemoval() throws {
        for status in [" M tracked\0", "?? untracked\0", "!! ignored\0", "R  destination\0source\0"] {
            let fixture = Fixture(); fixture.runner.status = Data(status.utf8)
            let inspection = try fixture.inspector.inspect(fixture.identity)
            XCTAssertFalse(inspection.clean)
            XCTAssertEqual(inspection.hasIgnored, status.hasPrefix("!!"))
            XCTAssertThrowsError(try fixture.inspector.remove(fixture.identity))
            XCTAssertFalse(fixture.runner.calls.contains { $0.contains("remove") })
        }
    }
    func testLocksAndOperationSentinelsBlockRemoval() throws {
        for path in ["/repo/.git/index.lock", "/repo/.git/worktrees/topic/MERGE_HEAD", "/repo/.git/refs/heads/topic.lock", "/repo/.git/worktrees/topic/rebase-merge"] {
            let fixture = Fixture(); fixture.fs.directory("/repo/.git/refs", 11); fixture.fs.directory("/repo/.git/refs/heads", 12)
            fixture.fs.file(path, 13, "")
            XCTAssertTrue(try fixture.inspector.inspect(fixture.identity).operationInProgress)
            XCTAssertThrowsError(try fixture.inspector.remove(fixture.identity))
            XCTAssertFalse(fixture.runner.calls.contains { $0.contains("remove") })
        }
    }
    func testReflogOrStashDoesNotRetainHEAD() throws {
        let fixture = Fixture(); fixture.runner.refs = ""
        XCTAssertFalse(try fixture.inspector.inspect(fixture.identity).retainedHEAD)
        XCTAssertThrowsError(try fixture.inspector.remove(fixture.identity))
        fixture.runner.refs = "refs/stash\n"
        XCTAssertThrowsError(try fixture.inspector.inspect(fixture.identity))
    }
    func testProcessUncertaintyBlocksRemoval() throws {
        let fixture = Fixture()
        for value in [WorktreeGitProcessSnapshot(records: [], complete: false), .init(records: [.init(pid: 10, ownerUID: 501, cwd: nil)], complete: true), .init(records: [.init(pid: 10, ownerUID: 502, cwd: "/repo")], complete: true), .init(records: [.init(pid: 10, ownerUID: 501, cwd: "/work/topic")], complete: true)] {
            fixture.process.value = value
            XCTAssertNotEqual(try fixture.inspector.processUse(path: "/work/topic"), .unused)
            XCTAssertThrowsError(try fixture.inspector.remove(fixture.identity))
        }
        XCTAssertFalse(fixture.runner.calls.contains { $0.contains("remove") })
    }
    func testRemovalUsesOnlyNonforceGitWorktreeRemoveAfterRevalidation() throws {
        let fixture = Fixture()
        try fixture.inspector.remove(fixture.identity)
        let removals = fixture.runner.calls.filter { $0.contains("remove") }
        XCTAssertEqual(removals.count, 1)
        XCTAssertEqual(Array(removals[0].suffix(4)), ["worktree", "remove", "--", "/work/topic"])
        XCTAssertFalse(removals[0].contains("--force"))
        XCTAssertTrue(fixture.runner.calls.filter { $0.contains("status") }.count >= 2)
    }
    func testIdentityMutationDuringScanPreventsRemoval() throws {
        let fixture = Fixture()
        fixture.runner.mutate = { args in if args.contains("status") { fixture.fs.directory("/work/topic", 999) } }
        XCTAssertThrowsError(try fixture.inspector.remove(fixture.identity))
        XCTAssertFalse(fixture.runner.calls.contains { $0.contains("remove") })
    }
    func testCommandFailureAndMalformedStatusNeverBecomeClean() throws {
        let fixture = Fixture(); fixture.runner.failure = 1
        XCTAssertThrowsError(try fixture.inspector.inspect(fixture.identity))
        fixture.runner.failure = 0
        for status in ["?? missing-nul", "bad\0", "R  destination\0"] {
            fixture.runner.status = Data(status.utf8)
            XCTAssertThrowsError(try fixture.inspector.inspect(fixture.identity))
        }
    }
    func testCreationInvocationNormalizesChainedCAndDropsBranchAndReason() throws {
        let fixture = Fixture()
        let invocation = try fixture.inspector.creationInvocation(cwd: "/repo", gitArguments: ["-C", "../work", "-C", "", "--git-dir=../repo/.git", "worktree", "add", "-b", "private-branch", "--reason", "private reason", "topic", "HEAD"])
        XCTAssertEqual(invocation?.cwd, "/work")
        XCTAssertEqual(invocation?.targetPath, "/work/topic")
        XCTAssertEqual(invocation?.gitArguments, ["--git-dir=/repo/.git", "worktree", "add", "--", "/work/topic"])
        XCTAssertTrue(fixture.runner.calls.isEmpty)
    }
    func testSnapshotParsesNULAndAssignsOnlyLinkedIdentity() throws {
        let fixture = Fixture()
        let snapshot = try fixture.inspector.snapshot(cwd: "/repo", gitArguments: ["worktree", "add", "../work/topic"])
        XCTAssertEqual(snapshot.worktrees.count, 2)
        XCTAssertTrue(snapshot.worktrees[0].isMain)
        XCTAssertNil(snapshot.worktrees[0].identity)
        XCTAssertEqual(snapshot.worktrees[1].identity, fixture.identity)
    }
    func testCleanLinkedWorktreeHasPersistentRetention() throws {
        let fixture = Fixture()
        let inspection = try fixture.inspector.inspect(fixture.identity)
        XCTAssertTrue(inspection.clean)
        XCTAssertFalse(inspection.hasIgnored)
        XCTAssertFalse(inspection.operationInProgress)
        XCTAssertTrue(inspection.retainedHEAD)
    }
    func testProcessPathComparisonUsesDirectoryBoundary() throws {
        let fixture = Fixture()
        fixture.process.value = WorktreeGitProcessSnapshot(records: [.init(pid: 10, ownerUID: 501, cwd: "/work/topic-other")], complete: true)
        XCTAssertEqual(try fixture.inspector.processUse(path: "/work/topic"), .unused)
        fixture.process.value = WorktreeGitProcessSnapshot(records: [.init(pid: 10, ownerUID: 501, cwd: "/work/topic/child")], complete: true)
        XCTAssertEqual(try fixture.inspector.processUse(path: "/work/topic"), .inUse)
    }
}

final class FakeFileSystem: WorktreeGitFileSystem {
    var nodes: [String: WorktreeGitFileInfo] = [:]
    var data: [String: Data] = [:]
    var observations = 0
    func canonicalPath(_ path: String) throws -> String { observations += 1; return URL(fileURLWithPath: path).standardizedFileURL.path }
    func info(_ path: String) throws -> WorktreeGitFileInfo? { observations += 1; return nodes[path] }
    func read(_ path: String, limit: Int) throws -> Data {
        observations += 1
        guard let value = data[path], value.count <= limit else { throw WorktreeGitError.unsafe("read") }; return value
    }
    func children(_ path: String, limit: Int) throws -> [String] {
        observations += 1
        let result = nodes.keys.filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == path && $0 != path }.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
        guard result.count <= limit else { throw WorktreeGitError.unsafe("children") }; return result
    }
    func directory(_ path: String, _ inode: UInt64) { nodes[path] = .init(identity: .init(device: 1, inode: inode), ownerUID: 501, kind: .directory) }
    func file(_ path: String, _ inode: UInt64, _ text: String) { data[path] = Data(text.utf8); nodes[path] = .init(identity: .init(device: 1, inode: inode), ownerUID: 501, kind: .regular, size: UInt64(text.utf8.count)) }
}
final class FakeRunner: WorktreeGitCommandRunning {
    var calls: [[String]] = []
    var environments: [[String: String]] = []
    var list = "worktree /repo\0HEAD \(String(repeating: "a", count: 40))\0branch refs/heads/main\0\0worktree /work/topic\0HEAD \(String(repeating: "b", count: 40))\0branch refs/heads/topic\0\0"
    var status = Data()
    var index = Data("H tracked\0".utf8)
    var sparseConfig = ""
    var filterKeys = Data()
    var filterStatus: Int32?
    var refs = "refs/heads/topic\n"
    var verifiedHEAD = String(repeating: "b", count: 40)
    var failure: Int32 = 0
    var mutate: (([String]) -> Void)?
    func run(arguments: [String], environment: [String: String], timeout: TimeInterval, limit: Int) throws -> WorktreeGitCommandResult {
        calls.append(arguments); environments.append(environment); mutate?(arguments)
        let text: String
        if arguments.contains("--git-common-dir") { text = "/repo/.git\n" }
        else if arguments.contains("list") { text = list }
        else if arguments.contains("status") { return .init(status: failure, stdout: status) }
        else if arguments.contains("ls-files") { return .init(status: failure, stdout: index) }
        else if arguments.contains("config") && arguments.contains("--name-only") { return .init(status: filterStatus ?? (filterKeys.isEmpty ? 1 : failure), stdout: filterKeys) }
        else if arguments.contains("config") { return .init(status: sparseConfig.isEmpty ? 1 : failure, stdout: Data(sparseConfig.utf8)) }
        else if arguments.contains("for-each-ref") { text = refs }
        else if arguments.contains("--verify") { text = verifiedHEAD + "\n" }
        else if arguments.contains("remove") { text = "" }
        else { throw WorktreeGitError.unsafe("unexpected command") }
        return .init(status: failure, stdout: Data(text.utf8))
    }
}
final class FakeProcessProbe: WorktreeGitProcessProbing {
    var value = WorktreeGitProcessSnapshot(records: [], complete: true)
    var calls = 0
    func snapshot(limit: Int) throws -> WorktreeGitProcessSnapshot { calls += 1; return value }
}
final class Fixture {
    let fs = FakeFileSystem()
    let runner = FakeRunner()
    let process = FakeProcessProbe()
    lazy var inspector = WorktreeGitInspector(runner: runner, fileSystem: fs, processProbe: process, userID: 501)
    var identity: WorktreeIdentity { .init(path: "/work/topic", commonDirectory: "/repo/.git", adminDirectory: "/repo/.git/worktrees/topic", pathIdentity: .init(device: 1, inode: 5), gitFileIdentity: .init(device: 1, inode: 6), adminIdentity: .init(device: 1, inode: 4), commonIdentity: .init(device: 1, inode: 2)) }
    init() {
        fs.directory("/", 90); fs.directory("/repo", 1); fs.directory("/repo/.git", 2); fs.directory("/repo/.git/worktrees", 3); fs.directory("/repo/.git/worktrees/topic", 4)
        fs.directory("/work", 91); fs.directory("/work/topic", 5); fs.directory("/work/topic/child", 8); fs.directory("/work/topic-other", 9)
        fs.file("/work/topic/.git", 6, "gitdir: /repo/.git/worktrees/topic\n")
        fs.file("/repo/.git/worktrees/topic/commondir", 7, "../..\n")
        fs.file("/repo/.git/worktrees/topic/gitdir", 10, "/work/topic/.git\n")
    }
}
