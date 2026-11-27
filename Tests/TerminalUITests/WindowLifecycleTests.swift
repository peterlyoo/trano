import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class WindowLifecycleTests: XCTestCase {
    // Implements: FR-NOTIFY-2
    @MainActor func testBackgroundServiceNeverTerminatesWhenItsLastWindowCloses() {
        let delegate = ApplicationDelegate()
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        delegate.isBackgroundService = true
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    // Implements: FR-NAV-6, U01
    @MainActor func testWorkspaceWindowUsesARCManagedCloseOwnershipAndKeepsTransparency() throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 700))
        let window = WorkspaceWindow.make(contentRect: content.frame, contentView: content)
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
        defer { window.isReleasedWhenClosed = false; window.close() }
        XCTAssertFalse(window.isReleasedWhenClosed, "An ARC-owned window must not release itself during close animations")
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, NSColor.clear)
        XCTAssertTrue(window.contentView === content)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    }

    // Implements: FR-NAV-6, U01
    @MainActor func testAnimatedCloseRemovesOwnedWindowAndDrainsSafelyAcrossRepeatedWindows() async throws {
        if ProcessInfo.processInfo.environment["TRANO_NATIVE_WINDOW_CLOSE_FIXTURE"] != "1" {
            try await runAnimatedCloseFixture()
            return
        }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-close-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = ApplicationDelegate()
        for index in 0..<8 {
            weak var released: NSWindow?
            var closed = false
            autoreleasepool {
                let model = AppStore(runtime: runtime)
                let window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 960, height: 700), contentView: NSView())
                XCTAssertFalse(window.isReleasedWhenClosed)
                guard !window.isReleasedWhenClosed else {
                    window.isReleasedWhenClosed = false
                    window.close()
                    return
                }
                released = window
                window.delegate = delegate
                delegate.windows[window] = model
                delegate.window = window
                delegate.store = model
                window.orderFrontRegardless()
                window.setFrame(NSRect(x: -12000, y: -12000, width: 962 + index, height: 702), display: true, animate: true)
                window.close()
                XCTAssertTrue(delegate.windows.isEmpty)
                XCTAssertNil(delegate.window)
                XCTAssertNil(delegate.store)
                closed = true
            }
            XCTAssertTrue(closed)
            let deadline = Date().addingTimeInterval(2)
            while autoreleasepool(invoking: { released != nil }) && Date() < deadline {
                autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(released, "The closed native window must drain after AppKit animation cleanup")
        }
    }

    @MainActor private func runAnimatedCloseFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-close-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputURL = root.appendingPathComponent("xctest.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "TerminalUITests.WindowLifecycleTests/testAnimatedCloseRemovesOwnedWindowAndDrainsSafelyAcrossRepeatedWindows", Bundle(for: WindowLifecycleTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["TRANO_NATIVE_WINDOW_CLOSE_FIXTURE"] = "1"
        environment.removeValue(forKey: "XCTestConfigurationFilePath")
        environment.removeValue(forKey: "XCTestSessionIdentifier")
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = Date().addingTimeInterval(40)
        while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let stopDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(25)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let exitDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < exitDeadline { try await Task.sleep(for: .milliseconds(25)) }
        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertFalse(timedOut, "The isolated native close fixture timed out:\n" + output)
        XCTAssertFalse(process.isRunning, "The isolated native close fixture did not exit:\n" + output)
        guard !process.isRunning else { return }
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("Executed 1 test"), "The native close fixture must execute its selected test:\n" + output)
    }

    // Implements: FR-NAV-1, FR-NAV-6, U01
    @MainActor func testFirstWindowShowsATerminalAndClosingItsLastTabDoesNotBootstrapAgain() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-first-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
        let store = AppStore(runtime: runtime, bootstrapIfEmpty: true)
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 1000, height: 700), contentView: hosting)
        defer {
            for terminal in store.terminalViews.values { terminal.terminate() }
            store.terminalViews.removeAll()
            window.isReleasedWhenClosed = false
            window.close()
            runtime.shutdownTestHost()
            try? FileManager.default.removeItem(at: root)
        }
        let loaded = Date().addingTimeInterval(4)
        while store.loading && Date() < loaded { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(store.loading)
        let id = try XCTUnwrap(store.focusedID)
        let attached = Date().addingTimeInterval(4)
        while store.terminalViews[id]?.process.running != true && Date() < attached {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let terminal = try XCTUnwrap(store.terminalViews[id])
        XCTAssertTrue(terminal.process.running)
        XCTAssertGreaterThan(terminal.bounds.width, 400)
        XCTAssertGreaterThan(terminal.bounds.height, 300)
        let pane = try XCTUnwrap(runtime.list().first { $0.id == id })
        let tab = try XCTUnwrap(store.selectedTab?.id)
        store.perform { try $0.update { $0.layout.closeTab(tab) } }
        let closed = Date().addingTimeInterval(4)
        while !store.state.layout.tabs.isEmpty && Date() < closed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.state.layout.tabs.isEmpty)
        store.refresh()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(store.state.layout.tabs.isEmpty)
        XCTAssertEqual(try runtime.list().count, 1)
        XCTAssertEqual(try runtime.list().first?.pid, pane.pid)
        XCTAssertTrue(try XCTUnwrap(runtime.list().first).alive)
    }
}
