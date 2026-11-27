import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class ProgramIconTests: XCTestCase {
    // Implements: FR-NAV-11
    func testFocusedProgramsTakePrecedenceOverAgentHistoryAndKeepManualNames() {
        var first = TerminalSession(id: "first", title: "First", cwd: "/tmp", pid: 1)
        first.agent = .claude; first.foregroundProgram = .k9s
        var second = TerminalSession(id: "second", title: "Second", cwd: "/tmp", pid: 2)
        second.agent = .codex; second.foregroundProgram = .kubernetesExec
        var tab = TerminalTab(paneID: first.id)
        tab.tree = .split(id: "split", axis: .horizontal, ratio: 0.5, first: .pane(first.id), second: .pane(second.id))
        tab.focusedPaneID = second.id
        let display = TabPresentation(tab: tab, sessions: [first, second])
        XCTAssertEqual(display.programs, [.kubernetesExec, .k9s])
        XCTAssertEqual(display.title, "Second")
        tab.focusedPaneID = first.id; tab.title = "Manual name"
        XCTAssertEqual(TabPresentation(tab: tab, sessions: [first, second]).programs, [.k9s, .kubernetesExec])
        XCTAssertEqual(TabPresentation(tab: tab, sessions: [first, second]).title, "Manual name")
        first.foregroundProgram = .zsh
        XCTAssertEqual(first.displayProgram, .zsh)
        XCTAssertEqual(first.agent, .claude)
        XCTAssertEqual(AgentKind.allCases.map(\.rawValue), ["shell", "claude", "codex"])
    }

    // Implements: FR-NAV-11
    @MainActor func testBundledProgramArtworkAndCompactStackRender() throws {
        for program in [TerminalProgram.zsh, .k9s, .kubernetesExec] {
            let image = try XCTUnwrap(ProgramArtwork.image(for: program), program.rawValue)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertLessThanOrEqual(bitmap.pixelsWide, 128)
            XCTAssertLessThanOrEqual(bitmap.pixelsHigh, 128)
        }
        let preview = VStack(alignment: .leading, spacing: 14) {
            ForEach([TerminalProgram.zsh, .k9s, .kubernetesExec], id: \.self) { program in
                HStack(spacing: 10) {
                    ProgramLogo(program: program).frame(width: 14, height: 14)
                    Text(program.displayName)
                }
            }
            HStack(spacing: 10) {
                TabAgentIcons(programs: [.kubernetesExec, .k9s, .zsh, .codex, .claude, .shell])
                Text("Focused program in front")
            }
        }.font(.system(size: 12)).foregroundStyle(.white).frame(width: 340, alignment: .leading)
            .padding(20).background(Color(white: 0.08))
        let renderer = ImageRenderer(content: preview); renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)
        if let path = ProcessInfo.processInfo.environment["TRANO_PROGRAM_ICON_SNAPSHOT"] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    // Implements: FR-NAV-11
    @MainActor func testForegroundCommandAndReturnToZshUpdateWithoutStateWritesOrClientReplacement() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-program-ui-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let code = root.appendingPathComponent("fake.c")
        try "#include <unistd.h>\nint main(void) { for (;;) pause(); }\n".write(to: code, atomically: true, encoding: .utf8)
        let program = root.appendingPathComponent("k9s")
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [code.path, "-o", program.path]; try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        runtime.isolatePaneHome(root)
        let pane = try runtime.create(title: "Programs", cwd: root.path, arguments: ["-f"])
        try runtime.update { $0.settings.automaticRestore = false; $0.layout.addTab(paneID: pane.id) }
        let store = AppStore(runtime: runtime, recoverOnStartup: false)
        let host = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 650), contentView: host)
        window.orderFrontRegardless()
        defer {
            let views = Array(store.terminalViews.values); store.terminalViews.removeAll(); views.forEach { $0.terminate() }
            window.close(); try? runtime.terminate(pane.id); runtime.shutdownTestHost(); try? FileManager.default.removeItem(at: root)
        }
        try await settle(host) { !store.loading && store.sessions.first?.displayProgram == .zsh && store.terminalViews[pane.id]?.process.running == true }
        let view = try XCTUnwrap(store.terminalViews[pane.id]); let clientPID = view.process.shellPid
        let state = try Data(contentsOf: root.appendingPathComponent("state.json"))
        try runtime.send(pane.id, text: ShellQuote.quote(program.path), enter: true)
        try await settle(host) { store.sessions.first?.displayProgram == .k9s }
        let tabID = try XCTUnwrap(store.selectedTab?.id)
        XCTAssertEqual(region("tab-agents-" + tabID, in: host)?.accessibilityLabel(), "k9s")
        XCTAssertEqual(region("pane-program-" + pane.id, in: host)?.accessibilityLabel(), "k9s")
        try runtime.host.write(pane.id, Data([3]))
        try await settle(host) { store.sessions.first?.displayProgram == .zsh }
        XCTAssertTrue(store.terminalViews[pane.id] === view)
        XCTAssertEqual(view.process.shellPid, clientPID)
        XCTAssertEqual(store.sessions.first?.pid, pane.pid)
        XCTAssertEqual(store.sessions.first?.agent, .shell)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("state.json")), state)
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }

    @MainActor private func settle(_ host: NSView, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Program icon state did not settle")
    }
}
