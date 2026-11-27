import SwiftUI
import TerminalCore

struct TabPresentation: Equatable {
    let title: String
    let programs: [TerminalProgram]
    let focusedPaneID: String?

    init(tab: TerminalTab, sessions: [TerminalSession], focusedPaneID: String? = nil, preferGeneratedTitles: Bool = false) {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = [focusedPaneID, tab.focusedPaneID].compactMap { $0 } + tab.panes
        let focused = candidates.first { tab.panes.contains($0) && byID[$0] != nil }
        self.focusedPaneID = focused
        title = tab.title == "Terminal" ? focused.flatMap { byID[$0]?.displayTitle(preferGeneratedTitles: preferGeneratedTitles) } ?? tab.title : tab.title
        var ordered: [TerminalProgram] = []
        for id in (focused.map { [$0] } ?? []) + tab.panes {
            if let program = byID[id]?.displayProgram, !ordered.contains(program) { ordered.append(program) }
        }
        programs = ordered.isEmpty ? [.shell] : ordered
    }
}

extension AppStore {
    func presentation(for tab: TerminalTab) -> TabPresentation {
        TabPresentation(tab: tab, sessions: sessions, focusedPaneID: state.layout.selectedTabID == tab.id ? focusedID : nil, preferGeneratedTitles: terminalPreferences.preferGeneratedTitles)
    }
}

struct TabAgentIcons: View {
    let programs: [TerminalProgram]
    var limit = 5
    var colored = true
    var coloredPrograms: Set<TerminalProgram>?
    var shellTheme = InterfaceShellIconTheme.artwork
    var themeForeground = Color.primary
    var themeAccent = Color.accentColor

    init(programs: [TerminalProgram]) { self.programs = programs }
    init(agents: [AgentKind]) { programs = agents.map(TerminalProgram.init(agent:)) }

    var body: some View {
        let visible = Array(programs.prefix(max(0, limit)))
        return ZStack(alignment: .leading) {
            ForEach(Array(visible.enumerated()), id: \.element) { index, program in
                ProgramLogo(program: program, tint: iconTint(program), monochrome: !isColored(program) || (isShell(program) && shellTheme != .artwork))
                    .frame(width: 14, height: 14)
                    .offset(x: CGFloat(index) * min(3, 6 / CGFloat(max(1, visible.count - 1))), y: index == 0 ? 1 : -1)
                    .zIndex(Double(visible.count - index))
            }
        }.frame(width: visible.isEmpty ? 0 : 20, height: 16, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Programs")
            .accessibilityValue(programs.map(\.displayName).joined(separator: ", "))
            .allowsHitTesting(false)
    }
    private func isColored(_ program: TerminalProgram) -> Bool { colored && (coloredPrograms?.contains(program) ?? true) }
    private func isShell(_ program: TerminalProgram) -> Bool { program == .shell || program == .zsh }
    private func iconTint(_ program: TerminalProgram) -> Color? {
        if isShell(program), shellTheme == .accent { return themeAccent }
        if isShell(program), shellTheme == .theme { return themeForeground }
        if !isColored(program) { return themeForeground }
        return nil
    }

}
