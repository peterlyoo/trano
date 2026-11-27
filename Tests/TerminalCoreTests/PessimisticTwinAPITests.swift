import Foundation
import XCTest
@testable import TerminalCore

final class PessimisticTwinAPITests: XCTestCase {
    // Implements: FR-TWIN-1, FR-TWIN-6, FR-TWIN-10
    func testStatusIsReadOnlyAndControlsRequireLocalAuthority() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-twin-api-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root), service = APIService(runtime: runtime)
        let response = service.route(APIRequest(method: "twins.status"))
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?["runs"], .array([]))
        let invalid = service.route(APIRequest(method: "twins.enable", params: ["paneID": .string(UUID().uuidString), "mode": .string("code_review")]))
        XCTAssertNotNil(invalid.error)
        XCTAssertNotNil(service.route(APIRequest(method: "twins.resolve", params: ["choice": .string("merge")]), originPID: getpid()).error)
        XCTAssertTrue(try runtime.state().sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pessimistic-twins.json").path))
    }

    func testCommandPaletteProvidesTheSameNativeTwinEntry() {
        XCTAssertTrue(ActionCatalog.all.contains { $0.id == "agent.pessimistic-twin" && $0.requiresUI })
    }
}
