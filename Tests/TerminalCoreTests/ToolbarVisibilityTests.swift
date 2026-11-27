import Foundation
import XCTest
@testable import TerminalCore

final class ToolbarVisibilityTests: XCTestCase {
    // Implements: FR-TOOLBAR-3
    func testLegacyDefaultsAndHiddenItemsRoundTripWithoutLosingUnknownFutureIDs() throws {
        let legacy = try JSONDecoder().decode(InterfacePreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(try hidden(legacy), [])
        let value = try preferences(["activity", "future-tool"])
        XCTAssertEqual(try hidden(value), ["activity", "future-tool"])
        XCTAssertEqual(try JSONDecoder().decode(InterfacePreferences.self, from: JSONEncoder().encode(value)), value)
    }

    // Implements: FR-TOOLBAR-3
    func testPerItemDraftMergeRetainsConcurrentIconsAndUnrelatedSettings() throws {
        let baseline = try preferences(["activity", "future-tool"])
        var draft = InterfacePreferencesDraft(baseline)
        draft.value = try preferences(["decisions", "future-tool"])
        var concurrent = try preferences(["activity", "future-tool", "remote-hosts"])
        concurrent.paddingX = 12
        let result = try draft.applying(to: concurrent)
        XCTAssertEqual(try hidden(result), ["decisions", "future-tool", "remote-hosts"])
        XCTAssertEqual(result.paddingX, 12)
        draft.cancel()
        XCTAssertEqual(draft.value, baseline)
    }

    // Implements: FR-TOOLBAR-3
    func testSidecarPersistsAndMergesVisibilityWithoutPrimaryStateRewrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-toolbar-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InterfacePreferencesStore(root: root)
        let baseline = try store.load()
        try store.save(preferences(["activity"]), baseline: baseline)
        try store.save(preferences(["decisions"]), baseline: baseline)
        XCTAssertEqual(try hidden(InterfacePreferencesStore(root: root).load()), ["activity", "decisions"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }

    private func preferences(_ items: [String]) throws -> InterfacePreferences {
        try JSONDecoder().decode(InterfacePreferences.self, from: JSONSerialization.data(withJSONObject: ["hiddenToolbarItems": items]))
    }
    private func hidden(_ value: InterfacePreferences) throws -> Set<String> {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        return Set(try XCTUnwrap(object["hiddenToolbarItems"] as? [String]))
    }
}
