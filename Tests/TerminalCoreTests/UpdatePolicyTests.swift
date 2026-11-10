import XCTest
@testable import TerminalCore

final class UpdatePolicyTests: XCTestCase {
    private var release: [String: Any] {
        ["SUFeedURL": "https://updates.example.org/trano/appcast.xml",
         "SUPublicEDKey": Data((1...32).map(UInt8.init)).base64EncodedString(),
         "CFBundleIdentifier": "dev.trano.app", "CFBundleVersion": "42",
         "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true]
    }

    // Implements: FR-UPDATE-1
    func testOnlyAuthenticatedReleaseMetadataEnablesUpdates() throws {
        let value = try UpdateConfiguration(info: release)
        XCTAssertEqual(value.feedURL.host, "updates.example.org")
        XCTAssertEqual(value.buildVersion, "42")
        XCTAssertThrowsError(try UpdateConfiguration(info: [:]))
        for field in ["SUPublicEDKey", "SUFeedURL", "CFBundleVersion", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var info = release
            info.removeValue(forKey: field)
            XCTAssertThrowsError(try UpdateConfiguration(info: info), field)
        }
    }

    // Implements: FR-UPDATE-1
    func testRejectsInsecureFeedAndMalformedKeyOrVersion() {
        for feed in ["http://updates.example.org/feed.xml", "file:///tmp/feed.xml", "https://user:secret@updates.example.org/feed.xml", "https://updates.example.org/feed.xml#fragment", "https:///feed.xml"] {
            var info = release; info["SUFeedURL"] = feed
            XCTAssertThrowsError(try UpdateConfiguration(info: info), feed)
        }
        for key in ["", "not-base64", Data(repeating: 0, count: 32).base64EncodedString(), Data(repeating: 1, count: 31).base64EncodedString()] {
            var info = release; info["SUPublicEDKey"] = key
            XCTAssertThrowsError(try UpdateConfiguration(info: info))
        }
        for version in ["", "0", "-1", "dev", "1; echo bad", "1.2.3.4"] {
            var info = release; info["CFBundleVersion"] = version
            XCTAssertThrowsError(try UpdateConfiguration(info: info), version)
        }
    }

    // Implements: FR-UPDATE-2
    func testHelperAndSnapshotsNeverStartAnUpdater() {
        XCTAssertTrue(UpdateLaunchPolicy.shouldStart(arguments: ["TranoApp"], bundleIdentifier: "dev.trano.app"))
        XCTAssertFalse(UpdateLaunchPolicy.shouldStart(arguments: ["TranoApp", "--service"], bundleIdentifier: "dev.trano.app"))
        XCTAssertFalse(UpdateLaunchPolicy.shouldStart(arguments: ["TranoApp", "--snapshot", "/tmp/image.png"], bundleIdentifier: "dev.trano.app"))
        XCTAssertFalse(UpdateLaunchPolicy.shouldStart(arguments: ["TranoApp"], bundleIdentifier: "dev.trano.activity"))
        XCTAssertFalse(UpdateLaunchPolicy.shouldStart(arguments: ["TranoApp"], bundleIdentifier: nil))
    }
}
