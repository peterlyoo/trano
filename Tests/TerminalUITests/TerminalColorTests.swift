import AppKit
import SwiftTerm
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor private final class ColorReplyRecorder: NSObject, TerminalViewDelegate {
    var reply = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { reply.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

final class TerminalColorTests: XCTestCase {
    // Implements: U02, FR-CORE-3
    @MainActor func testStatuslinePaletteRetainsStandardXtermSaturation() throws {
        _ = NSApplication.shared
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.configure(TerminalSettings())
        let recorder = ColorReplyRecorder()
        view.terminalDelegate = recorder
        view.feed(text: "\u{1b}]4;31;?\u{7}\u{1b}]4;70;?\u{7}\u{1b}]4;202;?\u{7}")
        let deadline = Date().addingTimeInterval(2)
        while recorder.reply.filter({ $0 == 27 }).count < 6 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let reply = String(decoding: recorder.reply, as: UTF8.self).lowercased()
        XCTAssertTrue(reply.contains("4;31;rgb:0000/8787/afaf"), reply.debugDescription)
        XCTAssertTrue(reply.contains("4;70;rgb:5f5f/afaf/0000"), reply.debugDescription)
        XCTAssertTrue(reply.contains("4;202;rgb:ffff/5f5f/0000"), reply.debugDescription)
    }

    // Implements: U02, FR-CORE-3
    @MainActor func testANSIIndexedAndTrueColorSurviveRealHostPTY() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-color-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "Colors", cwd: root.path, arguments: ["-df"])
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 800, height: 420))
        defer {
            view.terminate()
            try? runtime.terminate(pane.id)
            runtime.shutdownTestHost()
            try? FileManager.default.removeItem(at: root)
        }
        view.configure(TerminalSettings())
        let attach = try runtime.attachCommand(pane.id)
        view.startProcess(executable: attach.executable, args: attach.arguments,
                          environment: runtime.testAttachEnvironment(pane.id))
        try runtime.send(pane.id, text: "printf '\\033[2J\\033[H\\033[31mR\\033[38;5;202mP\\033[38;2;17;93;201mT\\033[0mN\\n'", enter: true)
        let deadline = Date().addingTimeInterval(5)
        var marker: TerminalContentRowSnapshot?
        repeat {
            marker = view.terminalContentSnapshot(region: .viewport)?.rows.first { $0.text.hasPrefix("RPTN") }
            if marker != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        let row = try XCTUnwrap(marker, "Color marker did not reach real renderer")
        XCTAssertEqual(row.cells[0].attribute.fg, .ansi256(code: 1))
        XCTAssertEqual(row.cells[1].attribute.fg, .ansi256(code: 202))
        XCTAssertEqual(row.cells[2].attribute.fg, .trueColor(red: 17, green: 93, blue: 201))
        XCTAssertEqual(row.cells[3].attribute.fg, .defaultColor)
    }
}
