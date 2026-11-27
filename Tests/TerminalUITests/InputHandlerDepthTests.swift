import AppKit
import XCTest
@testable import SwiftTerm
@testable import TranoApp

@MainActor final class InputHandlerDepthTests: XCTestCase {
    // Regression for a stack overflow on com.apple.libdispatch-io.opq: each input event used to wrap the
    // stored handler and every write completion in more thunks, so releasing a completion recursed once per
    // event since the handler was installed.
    func testInputHandlerAndCompletionDepthStayFlatAcrossManyEvents() {
        _ = NSApplication.shared
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let depths = SwiftTerm.Locked<[Int]>([])
        let completionDepths = SwiftTerm.Locked<[Int]>([])
        view.setProcessInputHandler { bytes, _, write in
            depths.withLock { $0.append(Thread.callStackSymbols.count) }
            write(bytes) { _ in completionDepths.withLock { $0.append(Thread.callStackSymbols.count) } }
        }
        for index in 0..<2_000 {
            if index.isMultiple(of: 2) { view.send(source: view, data: [0x61][...]) }
            else { view.sendUserInput(source: view, data: [0x62][...]) }
        }
        let handler = depths.withLock { $0 }, completion = completionDepths.withLock { $0 }
        XCTAssertGreaterThanOrEqual(handler.count, 1_000)
        XCTAssertEqual(completion.count, handler.count, "The inert writer completes every write synchronously")
        XCTAssertEqual(handler.last, handler.first, "Handler call depth grew with input count")
        XCTAssertEqual(completion.last, completion.first, "Write completion depth grew with input count")
    }
}
