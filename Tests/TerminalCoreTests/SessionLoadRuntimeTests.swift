import Foundation
import XCTest
@testable import TerminalCore

final class SessionLoadRuntimeTests: XCTestCase {
    // Implements: FR-LOAD-1, FR-LOAD-2, FR-LOAD-4
    func testTargetResolverUsesVerifiedPaneHostBackendAndGeneration() throws {
        let paneID = UUID().uuidString.lowercased()
        let session = TerminalSession(id: paneID, title: "pane", cwd: "/tmp", pid: 999)
        let launch = AgentLaunch(paneID: paneID, provider: .claude, providerSessionID: "provider",
            cwd: "/tmp", accountID: nil, configurationRoot: "/tmp/claude", bootID: "boot", processID: 15, providerPID: 20)
        let live = FakePaneBackend.pane(id: paneID, pid: 10, generation: "gen-a")
        let rows = SessionLoadTargetResolver.resolve(sessions: [session], launches: [launch], panes: [live])
        let target = try XCTUnwrap(rows.first)
        XCTAssertEqual(target.backendPID, 10)
        XCTAssertTrue(target.alive)
        XCTAssertEqual(target.providerPID, 20)
        XCTAssertEqual(target.providerSessionID, "provider")
        XCTAssertEqual(target.ownershipToken, "pty:gen-a:10:agent:" + launch.id)
        let missing = SessionLoadTargetResolver.resolve(sessions: [session], launches: [launch], panes: [])
        XCTAssertEqual(missing.first?.alive, false)
        XCTAssertEqual(missing.first?.ownershipToken, "missing:" + paneID + ":agent:" + launch.id)
        let ungenerated = SessionLoadTargetResolver.resolve(sessions: [session], launches: [launch],
            panes: [FakePaneBackend.pane(id: paneID, pid: 10, generation: nil)])
        XCTAssertEqual(ungenerated.first?.alive, false)
        let duplicate = SessionLoadTargetResolver.resolve(sessions: [session], launches: [launch],
            panes: [live, FakePaneBackend.pane(id: paneID, pid: 20, generation: "gen-b")])
        XCTAssertEqual(duplicate.first?.alive, false)
        let ambiguousLaunch = SessionLoadTargetResolver.resolve(sessions: [session], launches: [launch, launch], panes: [live])
        XCTAssertNil(ambiguousLaunch.first?.providerSessionID)
        XCTAssertEqual(ambiguousLaunch.first?.ownershipToken, "pty:gen-a:10:agent:shell")
    }

    // Implements: FR-LOAD-1, FR-LOAD-2, FR-LOAD-4
    func testPrivateHookBindingStorePersistsExactGenerationAndRejectsSymlinksAndUnknownSchema() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = SessionHookFileBinding(paneID: UUID().uuidString.lowercased(), ownershipToken: UUID().uuidString.lowercased(),
            providerSessionID: UUID().uuidString.lowercased(), configurationRoot: "/tmp/claude", relativePath: "projects/project/conversation.jsonl")
        let store = SessionHookBindingStore(root: root)
        try store.record(binding)
        XCTAssertEqual(try SessionHookBindingStore(root: root).read(), [binding])
        let path = root.appendingPathComponent("session-load-hooks.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("{\"schemaVersion\":99,\"bindings\":[]}".utf8).write(to: path)
        XCTAssertThrowsError(try store.read())
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent("unmanaged"))
        XCTAssertThrowsError(try store.record(binding))
    }
}
