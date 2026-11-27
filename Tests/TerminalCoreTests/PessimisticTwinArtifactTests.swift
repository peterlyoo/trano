import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinArtifactTests: XCTestCase {
    // Implements: FR-TWIN-5, FR-TWIN-8, FR-TWIN-9.
    func testQuarantinePreservesWholeIgnoredTreesEmptyDirectoriesRawBytesAndSymlinks() throws {
        let f = ArtifactFixture()
        let plan = try XCTUnwrap(f.plan())
        XCTAssertEqual(plan.roots, [".build", "node_modules"])
        XCTAssertEqual(plan.records.first { $0.path == ".build/output.bin" }?.sha256, ArtifactMemoryFS.hash(Data([0, 255, 10])))
        var stages: [String] = []
        let destination = try f.quarantine.perform(plan, recordMutation: { stages.append($0.rawValue) })
        XCTAssertEqual(destination, f.location + "/artifacts")
        XCTAssertEqual(f.fs.data[destination + "/files/.build/output.bin"], Data([0, 255, 10]))
        XCTAssertEqual(f.fs.nodes[destination + "/files/.build/empty"]?.metadata.kind, .directory)
        XCTAssertEqual(f.fs.data[destination + "/files/node_modules/.bin/tool"], Data("../../outside".utf8))
        XCTAssertNil(f.fs.nodes[f.worktree + "/.build"])
        XCTAssertEqual(f.fs.data[f.worktree + "/Sources/a.swift"], Data("source".utf8))
        XCTAssertEqual(f.fs.data["/outside"], Data("keep".utf8))
        XCTAssertEqual(stages.first, "artifactsQuarantineWillStart")
        XCTAssertEqual(stages.last, "artifactsQuarantined")
        XCTAssertNotNil(f.fs.data[destination + "/plan.json"])
        XCTAssertNotNil(f.fs.data[destination + "/complete.json"])
    }
    func testTrackedOverlapUnsafePathsAndCanonicalAliasesHoldBeforeAnyMove() throws {
        for ignored in ["Sources/\0", "../outside\0", "/outside\0", ".git/\0", ".build//bad\0", ".build/\0.BUILD/\0"] {
            let f = ArtifactFixture()
            XCTAssertThrowsError(try f.quarantine.prepare(snapshot: f.snapshot, tip: f.tip, ignored: Data(ignored.utf8), protectedPaths: ["Sources/a.swift"]))
            XCTAssertTrue(f.fs.moves.isEmpty)
        }
        let f = ArtifactFixture()
        XCTAssertThrowsError(try f.quarantine.prepare(snapshot: f.snapshot, tip: f.tip, ignored: Data(".build/\0".utf8), protectedPaths: [".BUILD/tracked"]))
    }
    func testExistingArtifactOrPendingNamespaceIsRetainedWithoutOverwrite() throws {
        for name in ["artifacts", "artifacts.pending-existing"] {
            let f = ArtifactFixture(); f.fs.directory(f.location + "/" + name)
            XCTAssertThrowsError(try f.plan()); XCTAssertTrue(f.fs.moves.isEmpty)
        }
    }
    func testConcurrentArtifactMutationBeforeCommitHoldsWithoutMovingAnything() throws {
        let f = ArtifactFixture(), plan = try XCTUnwrap(f.plan())
        f.fs.file(f.worktree + "/.build/output.bin", Data("changed".utf8))
        XCTAssertThrowsError(try f.quarantine.perform(plan))
        XCTAssertTrue(f.fs.moves.isEmpty)
        XCTAssertEqual(f.fs.data[f.worktree + "/.build/output.bin"], Data("changed".utf8))
    }
    func testPartialBatchFailureRetainsAlreadyMovedAndUnmovedData() throws {
        let f = ArtifactFixture(), plan = try XCTUnwrap(f.plan())
        f.fs.failMoveNumber = 2
        XCTAssertThrowsError(try f.quarantine.perform(plan))
        XCTAssertEqual(f.fs.moves.count, 1)
        XCTAssertNotNil(f.fs.nodes[f.worktree + "/node_modules"])
        let retained = f.fs.data.filter { $0.key.contains("artifacts.pending-") && $0.key.hasSuffix("output.bin") }
        XCTAssertEqual(retained.values.first, Data([0, 255, 10]))
        XCTAssertNil(f.fs.nodes[f.location + "/artifacts"])
    }
    func testBoundsAndUnsupportedFileTypesHoldBeforeAnyMove() throws {
        for reason in ["entries", "bytes", "receipt", "hardlink", "special", "nested-git"] {
            let f = ArtifactFixture(); var q = f.quarantine
            if reason == "entries" { q.limits.entries = 1 }
            if reason == "bytes" { q.limits.bytes = 1 }
            if reason == "receipt" { q.limits.receiptBytes = 32 }
            if reason == "hardlink" { f.fs.replace(f.worktree + "/.build/output.bin", links: 2) }
            if reason == "special" { f.fs.replace(f.worktree + "/.build/output.bin", kind: .other) }
            if reason == "nested-git" { f.fs.directory(f.worktree + "/.build/.git") }
            XCTAssertThrowsError(try q.prepare(snapshot: f.snapshot, tip: f.tip, ignored: f.ignored, protectedPaths: ["Sources/a.swift"]), reason)
            XCTAssertTrue(f.fs.moves.isEmpty)
        }
    }
    func testSymlinkParentCannotRedirectArtifactTraversalIntoOutsideData() throws {
        let f = ArtifactFixture(); f.fs.file(f.worktree + "/cache", Data("/outside-dir".utf8), kind: .symlink)
        f.fs.directory("/outside-dir"); f.fs.file("/outside-dir/file", Data("keep".utf8))
        XCTAssertThrowsError(try f.quarantine.prepare(snapshot: f.snapshot, tip: f.tip, ignored: Data("cache/file\0".utf8), protectedPaths: []))
        XCTAssertTrue(f.fs.moves.isEmpty); XCTAssertEqual(f.fs.data["/outside-dir/file"], Data("keep".utf8))
    }
    func testCleanupQuarantineAndNonforceRemovalStayInsideRuntimeAdmission() throws {
        let f = ArtifactFixture(), inspector = ArtifactInspector(f)
        var admitted = false, deleted = false, stages: [String] = []
        let cleanup = artifactCleanup(f, inspector: inspector, revalidate: { XCTAssertTrue(admitted) }, delete: { XCTAssertTrue(admitted); deleted = true })
        try cleanup.cleanup(committing: { mutation in admitted = true; defer { admitted = false }; try mutation() }, recordMutation: { XCTAssertTrue(admitted); stages.append($0.rawValue) })
        XCTAssertEqual(inspector.removed.count, 1); XCTAssertTrue(deleted)
        XCTAssertEqual(f.fs.data[f.location + "/artifacts/files/.build/output.bin"], Data([0, 255, 10]))
        XCTAssertTrue(stages.contains("artifactsQuarantined")); XCTAssertEqual(stages.last, "branchDeleted")
    }
    func testFinalAdmissionRefusalLeavesIgnoredArtifactsAndBranchUntouched() throws {
        let f = ArtifactFixture(), inspector = ArtifactInspector(f)
        var deleted = false
        let cleanup = artifactCleanup(f, inspector: inspector, revalidate: {}, delete: { deleted = true })
        XCTAssertThrowsError(try cleanup.cleanup(committing: { _ in throw TwinGitError.unsafe("source input changed") }, recordMutation: { _ in }))
        XCTAssertTrue(f.fs.moves.isEmpty); XCTAssertTrue(inspector.removed.isEmpty); XCTAssertFalse(deleted)
    }
    func testFinalProcessUseAndIdentityChangesHoldBeforeArtifactMoves() throws {
        for reason in ["process", "identity"] {
            let f = ArtifactFixture(), inspector = ArtifactInspector(f)
            var valid = true, deleted = false
            let cleanup = artifactCleanup(f, inspector: inspector, revalidate: { if !valid { throw TwinGitError.unsafe("tip changed") } }, delete: { deleted = true })
            XCTAssertThrowsError(try cleanup.cleanup(committing: { mutation in
                if reason == "process" { inspector.active = true } else { valid = false }
                try mutation()
            }, recordMutation: { _ in }))
            XCTAssertTrue(f.fs.moves.isEmpty); XCTAssertTrue(inspector.removed.isEmpty); XCTAssertFalse(deleted)
        }
    }
    func testArtifactWriterAfterQuarantineKeepsWorktreeAndBranchForInspection() throws {
        let f = ArtifactFixture(), inspector = ArtifactInspector(f); inspector.artifactActive = true
        var deleted = false
        let cleanup = artifactCleanup(f, inspector: inspector, revalidate: {}, delete: { deleted = true })
        XCTAssertThrowsError(try cleanup.cleanup(committing: { try $0() }, recordMutation: { _ in }))
        XCTAssertNotNil(f.fs.data[f.location + "/artifacts/plan.json"])
        XCTAssertTrue(inspector.removed.isEmpty); XCTAssertFalse(deleted)
    }

    func testMalformedIgnoredFramingCannotSilentlySkipEmptyEntries() throws {
        let f = ArtifactFixture()
        for data in [Data([0]), Data(".build/\0\0".utf8)] {
            XCTAssertThrowsError(try f.quarantine.prepare(snapshot: f.snapshot, tip: f.tip, ignored: data, protectedPaths: []))
        }
    }
    func testHashingHappensOnlyOutsideFinalRuntimeAdmission() throws {
        let f = ArtifactFixture(), inspector = ArtifactInspector(f)
        var admitted = false, hashes = 0
        f.fs.onDigest = { XCTAssertFalse(admitted); hashes += 1 }
        let cleanup = artifactCleanup(f, inspector: inspector, revalidate: {}, delete: {})
        try cleanup.cleanup(committing: { mutation in admitted = true; defer { admitted = false }; try mutation() }, recordMutation: { _ in })
        XCTAssertEqual(hashes, 2)
    }

    func testNoIgnoredArtifactsNeedsNoQuarantine() throws {
        let f = ArtifactFixture()
        XCTAssertNil(try f.quarantine.prepare(snapshot: f.snapshot, tip: f.tip, ignored: Data(), protectedPaths: ["Sources/a.swift"]))
        XCTAssertTrue(f.fs.moves.isEmpty)
    }
}

private final class ArtifactFixture {
    let fs = ArtifactMemoryFS()
    let runID = "d53161fb-54d8-4cee-9f02-71f71a1ea675"
    let location = "/runtime/twins/d53161fb-54d8-4cee-9f02-71f71a1ea675/round-1"
    var worktree: String { location + "/worktree" }
    let tip = String(repeating: "b", count: 40)
    let ignored = Data(".build/\0node_modules/\0".utf8)
    var snapshot: TwinGitSnapshot {
        let identity = fs.nodes[worktree]!.metadata.identity
        let ownership = WorktreeIdentity(path: worktree, commonDirectory: "/source/.git", adminDirectory: "/source/.git/worktrees/twin", pathIdentity: identity, gitFileIdentity: identity, adminIdentity: identity, commonIdentity: identity)
        return .init(runID: runID, round: 1, repositoryRoot: "/source", sourceCWD: "/source", sourceGitDirectory: "/source/.git", commonDirectory: "/source/.git", sourceBranch: "refs/heads/main", sourceHEAD: String(repeating: "1", count: 40), sourceIndexSHA256: String(repeating: "2", count: 64), sourceTree: String(repeating: "3", count: 40), snapshotCommit: String(repeating: "a", count: 40), twinBranch: "refs/heads/trano/twins/" + runID + "/round-1", worktreePath: worktree, ownership: ownership)
    }
    var quarantine: TwinArtifactQuarantine { .init(root: URL(fileURLWithPath: "/runtime"), files: fs) }
    func plan() throws -> TwinArtifactPlan? { try quarantine.prepare(snapshot: snapshot, tip: tip, ignored: ignored, protectedPaths: ["Sources/a.swift"]) }
    init() {
        for path in ["/runtime", "/runtime/twins", "/runtime/twins/" + runID, location, worktree, worktree + "/Sources", worktree + "/.build", worktree + "/.build/empty", worktree + "/node_modules", worktree + "/node_modules/.bin"] { fs.directory(path) }
        fs.file(worktree + "/Sources/a.swift", Data("source".utf8)); fs.file(worktree + "/.build/output.bin", Data([0, 255, 10]))
        fs.file(worktree + "/node_modules/.bin/tool", Data("../../outside".utf8), kind: .symlink); fs.file("/outside", Data("keep".utf8))
    }
}
private final class ArtifactMemoryFS: TwinArtifactFileSystem {
    var nodes: [String: TwinArtifactNode] = [:], data: [String: Data] = [:]
    var next: UInt64 = 1
    var moves: [(String, String)] = []
    var failMoveNumber: Int?
    var onDigest: (() -> Void)?
    func directory(_ path: String) { let inode = next; next += 1; nodes[path] = .init(metadata: .init(identity: .init(device: 1, inode: inode), ownerUID: getuid(), kind: .directory, mode: 0o40700), links: 2) }
    func file(_ path: String, _ bytes: Data, kind: TwinGitNode.Kind = .regular) { let inode = next; next += 1; nodes[path] = .init(metadata: .init(identity: .init(device: 1, inode: inode), ownerUID: getuid(), kind: kind, mode: kind == .symlink ? 0o120777 : 0o100600, size: Int64(bytes.count)), links: 1); data[path] = bytes }
    func replace(_ path: String, kind: TwinGitNode.Kind? = nil, links: UInt64? = nil) { let old = nodes[path]!; nodes[path] = .init(metadata: .init(identity: old.metadata.identity, ownerUID: getuid(), kind: kind ?? old.metadata.kind, mode: old.metadata.mode, size: old.metadata.size), links: links ?? old.links) }
    func canonicalPath(_ path: String) throws -> String { guard nodes[path] != nil else { throw TwinGitError.unsafe("missing") }; return path }
    func artifactInfo(_ path: String) throws -> TwinArtifactNode? { var parent = ""; for component in path.split(separator: "/").dropLast() { parent += "/" + component; if nodes[parent]?.metadata.kind == .symlink { throw TwinGitError.unsafe("linked parent") } }; return nodes[path] }
    func info(_ path: String) throws -> TwinGitNode? { try artifactInfo(path)?.metadata }
    func read(_ path: String, limit: Int) throws -> Data { guard let bytes = data[path], bytes.count <= limit else { throw TwinGitError.unsafe("missing bytes") }; return bytes }
    func readLink(_ path: String, limit: Int) throws -> Data { try read(path, limit: limit) }
    func ensurePrivateDirectory(_ path: String) throws { if nodes[path] == nil { directory(path) } }
    func writePrivate(_ bytes: Data, path: String) throws { guard nodes[path] == nil else { throw TwinGitError.unsafe("exists") }; file(path, bytes) }
    func removePrivateFile(_ path: String) throws { nodes[path] = nil; data[path] = nil }
    func artifactChildren(_ path: String, limit: Int) throws -> [String] { guard try artifactInfo(path)?.metadata.kind == .directory else { throw TwinGitError.unsafe("not directory") }; let prefix = path + "/"; let names = nodes.keys.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }.map { String($0.dropFirst(prefix.count)) }.sorted(); guard names.count <= limit else { throw TwinGitError.unsafe("too many") }; return names }
    func artifactDigest(_ path: String, expected: TwinArtifactNode, limit: UInt64) throws -> String { onDigest?(); guard try artifactInfo(path) == expected, let bytes = data[path], UInt64(bytes.count) <= limit else { throw TwinGitError.unsafe("changed") }; return Self.hash(bytes) }
    func artifactMove(_ source: String, _ destination: String, expected: TwinArtifactNode) throws {
        guard failMoveNumber != moves.count + 1, try artifactInfo(source) == expected, nodes[destination] == nil else { throw TwinGitError.unsafe("changed move") }
        let selected = nodes.keys.filter { $0 == source || $0.hasPrefix(source + "/") }
        for key in selected { let target = destination + key.dropFirst(source.count); nodes[target] = nodes.removeValue(forKey: key); if let bytes = data.removeValue(forKey: key) { data[target] = bytes } }
        moves.append((source, destination))
    }
    func artifactCreatePrivateDirectory(_ path: String) throws { guard nodes[path] == nil else { throw TwinGitError.unsafe("existing quarantine") }; directory(path) }
    func artifactSyncDirectory(_ path: String) throws {}
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private func artifactCleanup(_ f: ArtifactFixture, inspector: ArtifactInspector, revalidate: @escaping () throws -> Void, delete: @escaping () throws -> Void) -> TwinGitArtifactCleanup {
    TwinGitArtifactCleanup(snapshot: f.snapshot, expectedTip: f.tip, root: URL(fileURLWithPath: "/runtime"), files: f.fs, inspector: inspector,
        command: { arguments in
            if arguments.contains("--ignored") { return f.fs.nodes[f.worktree + "/.build"] == nil && f.fs.nodes[f.worktree + "/node_modules"] == nil ? Data() : f.ignored }
            if arguments.first == "status" { return Data() }
            return Data("Sources/a.swift\0".utf8)
        }, review: { .init(tip: f.tip, changedFiles: [], clean: true) }, revalidate: revalidate, deleteBranch: delete)
}
private final class ArtifactInspector: WorktreeGitInspecting {
    let fixture: ArtifactFixture
    var removed: [WorktreeIdentity] = []
    var active = false, artifactActive = false
    init(_ fixture: ArtifactFixture) { self.fixture = fixture }
    func creationInvocation(cwd: String, gitArguments: [String]) throws -> WorktreeCreationInvocation? { nil }
    func snapshot(cwd: String, gitArguments: [String]) throws -> WorktreeRepositorySnapshot { fatalError("Not called") }
    func inspect(_ identity: WorktreeIdentity) throws -> WorktreeInspection {
        let ignored = fixture.fs.nodes[fixture.worktree + "/.build"] != nil || fixture.fs.nodes[fixture.worktree + "/node_modules"] != nil
        return .init(entry: .init(path: identity.path, head: fixture.tip, branch: fixture.snapshot.twinBranch, identity: identity), clean: !ignored, hasIgnored: ignored, operationInProgress: false, retainedHEAD: true)
    }
    func remove(_ identity: WorktreeIdentity) throws {
        let check = try inspect(identity)
        guard check.clean, !check.hasIgnored, !active else { throw TwinGitError.unsafe("Ordinary removal still refuses artifacts or processes") }
        removed.append(identity)
    }
    func processUse(path: String) throws -> WorktreeProcessUse { active || artifactActive && path.hasSuffix("/artifacts") ? .inUse : .unused }
}
