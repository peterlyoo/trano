import XCTest
@testable import TerminalCore

final class InstalledBuildCheckTests: XCTestCase {
    private let running = BuildIdentity(info: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "TranoBuildID": String(repeating: "a", count: 64)])

    private func bundle(buildID: String?, executable: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-installed-" + UUID().uuidString).appendingPathComponent("Trano.app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]
        if let buildID { info["TranoBuildID"] = buildID }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
        let binary = root.appendingPathComponent("Contents/MacOS/TranoApp")
        FileManager.default.createFile(atPath: binary.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: binary.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }

    func testReportsOnlyADifferentCompleteInstalledBuild() throws {
        XCTAssertNil(InstalledBuildCheck.pendingRestart(bundleURL: try bundle(buildID: running.buildID), running: running))
        let next = String(repeating: "b", count: 64)
        XCTAssertEqual(InstalledBuildCheck.pendingRestart(bundleURL: try bundle(buildID: next), running: running)?.buildID, next)
        XCTAssertNil(InstalledBuildCheck.pendingRestart(bundleURL: try bundle(buildID: nil), running: running))
        XCTAssertNil(InstalledBuildCheck.pendingRestart(bundleURL: try bundle(buildID: next, executable: false), running: running))
        XCTAssertNil(InstalledBuildCheck.pendingRestart(bundleURL: URL(fileURLWithPath: "/nonexistent/Trano.app"), running: running))
        let unbundled = BuildIdentity(info: [:])
        XCTAssertNil(InstalledBuildCheck.pendingRestart(bundleURL: try bundle(buildID: next), running: unbundled))
    }
}

final class TabSideTests: XCTestCase {
    func testTabIDsBesideStayInsideTheTabsWorkspaceInStripOrder() throws {
        var layout = WorkspaceLayout()
        layout.addWorkspace(title: "a")
        let a = (0..<4).map { layout.addTab(paneID: "a\($0)") }
        layout.addWorkspace(title: "b")
        let b = layout.addTab(paneID: "b0")
        XCTAssertEqual(layout.tabIDs(beside: a[1], side: .left), [a[0]])
        XCTAssertEqual(layout.tabIDs(beside: a[1], side: .right), [a[2], a[3]])
        XCTAssertEqual(layout.tabIDs(beside: a[0], side: .left), [])
        XCTAssertEqual(layout.tabIDs(beside: a[3], side: .right), [])
        XCTAssertEqual(layout.tabIDs(beside: b, side: .left), [])
        XCTAssertEqual(layout.tabIDs(beside: "missing", side: .right), [])
    }
}
