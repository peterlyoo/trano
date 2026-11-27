import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinArtifactFileTests: XCTestCase {
    // Implements: FR-TWIN-8, FR-TWIN-9. Fresh owned files only; no Git repository or lifecycle commands.
    func testNativeQuarantinePreservesRawBytesEmptyDirectoryAndLeafLink() throws {
        let f = try ArtifactFileFixture(); defer { f.close() }
        let plan = try XCTUnwrap(f.plan())
        let destination = try f.quarantine.perform(plan)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination + "/files/.build/output.bin")), Data([0, 255, 10, 13]))
        var directory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination + "/files/.build/empty", isDirectory: &directory)); XCTAssertTrue(directory.boolValue)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination + "/files/cache/link"), "../../outside.bin")
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("outside.bin")), Data("outside".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.worktree + "/tracked.swift")), Data("tracked".utf8))
        let receipt = try JSONDecoder().decode(TwinArtifactPlan.self, from: Data(contentsOf: URL(fileURLWithPath: destination + "/plan.json")))
        XCTAssertEqual(receipt, plan); XCTAssertTrue(FileManager.default.fileExists(atPath: destination + "/complete.json"))
    }
    func testNativeMutationBetweenHashAndAdmissionHoldsBeforeMovingFiles() throws {
        let f = try ArtifactFileFixture(); defer { f.close() }
        let plan = try XCTUnwrap(f.plan())
        try Data("changed artifact".utf8).write(to: URL(fileURLWithPath: f.worktree + "/.build/output.bin"))
        XCTAssertThrowsError(try f.quarantine.perform(plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree + "/.build/output.bin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.location + "/artifacts"))
    }
    func testNativeExclusiveRenameAndParentSymlinkRefuseWithoutOverwriting() throws {
        let f = try ArtifactFileFixture(); defer { f.close() }
        let source = f.worktree + "/.build/output.bin", destination = f.root.appendingPathComponent("existing.bin").path
        try Data("existing".utf8).write(to: URL(fileURLWithPath: destination))
        let node = try XCTUnwrap(f.files.artifactInfo(source))
        XCTAssertThrowsError(try f.files.artifactMove(source, destination, expected: node))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), Data("existing".utf8))
        try FileManager.default.createSymbolicLink(atPath: f.worktree + "/linked-parent", withDestinationPath: f.root.path)
        XCTAssertThrowsError(try f.files.artifactInfo(f.worktree + "/linked-parent/outside.bin"))
        XCTAssertThrowsError(try f.quarantine.prepare(snapshot: f.snapshot, tip: f.tip, ignored: Data("linked-parent/outside.bin\0".utf8), protectedPaths: []))
    }
    func testNativeQuarantineDirectoryCreationIsExclusive() throws {
        let f = try ArtifactFileFixture(); defer { f.close() }
        let path = f.location + "/exclusive"
        try f.files.artifactCreatePrivateDirectory(path)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path + "/data"))
        XCTAssertThrowsError(try f.files.artifactCreatePrivateDirectory(path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path + "/data")), Data("keep".utf8))
    }

    func testNativeHardlinkAndSpecialFileHoldWithoutFollowingOrRemovingThem() throws {
        let f = try ArtifactFileFixture(); defer { f.close() }
        try FileManager.default.linkItem(atPath: f.root.appendingPathComponent("outside.bin").path, toPath: f.worktree + "/.build/linked.bin")
        XCTAssertThrowsError(try f.plan())
        try FileManager.default.removeItem(atPath: f.worktree + "/.build/linked.bin")
        XCTAssertEqual(mkfifo(f.worktree + "/.build/pipe", 0o600), 0)
        XCTAssertThrowsError(try f.plan())
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("outside.bin")), Data("outside".utf8))
    }
}

private final class ArtifactFileFixture {
    let files = TwinNativeGitFileSystem()
    let root: URL
    let runID = UUID().uuidString.lowercased()
    let tip = String(repeating: "b", count: 40)
    var location: String { root.path + "/twins/" + runID + "/round-1" }
    var worktree: String { location + "/worktree" }
    var quarantine: TwinArtifactQuarantine { .init(root: root, files: files) }
    var snapshot: TwinGitSnapshot {
        let identity = try! files.artifactInfo(worktree)!.metadata.identity
        let ownership = WorktreeIdentity(path: worktree, commonDirectory: "/source/.git", adminDirectory: "/source/.git/worktrees/twin", pathIdentity: identity, gitFileIdentity: identity, adminIdentity: identity, commonIdentity: identity)
        return .init(runID: runID, round: 1, repositoryRoot: "/source", sourceCWD: "/source", sourceGitDirectory: "/source/.git", commonDirectory: "/source/.git", sourceBranch: "refs/heads/main", sourceHEAD: String(repeating: "a", count: 40), sourceIndexSHA256: String(repeating: "c", count: 64), sourceTree: String(repeating: "d", count: 40), snapshotCommit: String(repeating: "e", count: 40), twinBranch: "refs/heads/trano/twins/" + runID + "/round-1", worktreePath: worktree, ownership: ownership)
    }
    init() throws {
        let parent = try files.canonicalPath(FileManager.default.temporaryDirectory.path)
        root = URL(fileURLWithPath: parent).appendingPathComponent("trano-artifact-files-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for path in [root.path + "/twins", root.path + "/twins/" + runID, location, worktree, worktree + "/.build", worktree + "/.build/empty", worktree + "/cache"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try Data([0, 255, 10, 13]).write(to: URL(fileURLWithPath: worktree + "/.build/output.bin"))
        try Data("tracked".utf8).write(to: URL(fileURLWithPath: worktree + "/tracked.swift"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.bin"))
        try FileManager.default.createSymbolicLink(atPath: worktree + "/cache/link", withDestinationPath: "../../outside.bin")
    }
    func plan() throws -> TwinArtifactPlan? { try quarantine.prepare(snapshot: snapshot, tip: tip, ignored: Data(".build/\0cache/\0".utf8), protectedPaths: ["tracked.swift"]) }
    func close() { try? FileManager.default.removeItem(at: root) }
}
