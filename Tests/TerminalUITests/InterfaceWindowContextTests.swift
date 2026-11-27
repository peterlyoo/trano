import AppKit
import Combine
import XCTest
@testable import TranoApp

@MainActor final class InterfaceWindowContextTests: XCTestCase {
    func testRefreshDefersPublicationBeyondRepresentableUpdateAndSuppressesUnchangedBursts() async {
        _ = NSApplication.shared
        let context = InterfaceWindowContext()
        var publications = 0
        let observation = context.objectWillChange.sink { publications += 1 }
        for _ in 0..<64 { context.refresh() }
        XCTAssertEqual(publications, 0, "A representable refresh cannot publish during its update")
        for _ in 0..<4 { await Task.yield() }
        publications = 0
        for _ in 0..<64 { context.refresh() }
        XCTAssertEqual(publications, 0)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(publications, 0, "Unchanged native state must not trigger another SwiftUI update")
        withExtendedLifetime(observation) {}
    }

    func testDeferredRefreshDoesNotRetainAnUnmountedContext() async {
        _ = NSApplication.shared
        var context: InterfaceWindowContext? = InterfaceWindowContext()
        weak var retained = context
        context?.refresh()
        context = nil
        XCTAssertNil(retained)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNil(retained)
    }
}
