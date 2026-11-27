import Foundation
import XCTest
@testable import TerminalCore

final class TailscaleStatusEventsTests: XCTestCase {
    // Implements: FR-SET-16, FR-SET-17, FR-SET-18, FR-SET-27
    func testTypedNetworkEventsEmitOncePerEpisodeAndRearmAfterSuccess() {
        let observer = TailscaleStatusEvents()
        XCTAssertEqual(observer.observe(state: "NeedsLogin", failed: false).map(\.kind), [.tailscaleSignIn])
        XCTAssertTrue(observer.observe(state: "NeedsLogin", failed: false).isEmpty)
        XCTAssertEqual(observer.observe(state: "NeedsMachineAuth", failed: false).map(\.kind), [.tailscaleDeviceApproval])
        XCTAssertTrue(observer.observe(state: "NeedsMachineAuth", failed: false).isEmpty)
        XCTAssertEqual(observer.observe(state: nil, failed: true).map(\.kind), [.tailscaleFailure])
        XCTAssertTrue(observer.observe(state: nil, failed: true).isEmpty)
        XCTAssertTrue(observer.observe(state: "Running", failed: false).isEmpty)
        XCTAssertEqual(observer.observe(state: "NeedsLogin", failed: false).map(\.kind), [.tailscaleSignIn])
        XCTAssertEqual(observer.observe(state: nil, failed: true).map(\.kind), [.tailscaleFailure])
    }
    // Implements: FR-SET-27
    func testAuthenticationURLParserAcceptsOnlyBoundedHTTPSWithoutCredentials() {
        let data = Data("Sign in: https://login.example.test/a/fixture\nhttp://bad.test/path https://user:secret@bad.test/path\n".utf8)
        XCTAssertEqual(TailscaleStatusEvents.authenticationURLs(in: data).map(\.absoluteString), ["https://login.example.test/a/fixture"])
        XCTAssertTrue(TailscaleStatusEvents.authenticationURLs(in: Data(repeating: 65, count: 1_048_577)).isEmpty)
    }
}
