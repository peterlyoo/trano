import Foundation

public struct WorkspaceRecord: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString.lowercased()
    public var title: String
    public var selectedTabID: String?
    public var focusedPaneID: String?
    public var collapsed = false
    public var closed = false
}

public struct WorkspaceLayout: Codable, Equatable {
    public var workspaces: [WorkspaceRecord] = []
    public var tabs: [TerminalTab] = []
    public var closedTabs: [TerminalTab] = []
    public var selectedWorkspaceID: String?
    public var selectedTabID: String?
    public var focusedPaneID: String?
    public var currentTabs: [TerminalTab] { tabs.filter { $0.workspaceID == selectedWorkspaceID } }
    public init() {}

    private enum CodingKeys: String, CodingKey { case workspaces, tabs, closedTabs, selectedWorkspaceID, selectedTabID, focusedPaneID }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try box.decode([TerminalTab].self, forKey: .tabs)
        closedTabs = try box.decodeIfPresent([TerminalTab].self, forKey: .closedTabs) ?? []
        workspaces = try box.decodeIfPresent([WorkspaceRecord].self, forKey: .workspaces) ?? []
        selectedWorkspaceID = try box.decodeIfPresent(String.self, forKey: .selectedWorkspaceID)
        selectedTabID = try box.decodeIfPresent(String.self, forKey: .selectedTabID)
        focusedPaneID = try box.decodeIfPresent(String.self, forKey: .focusedPaneID)
        if workspaces.isEmpty && !tabs.isEmpty {
            var workspace = WorkspaceRecord(title: "Workspace")
            workspace.id = "00000000-0000-4000-8000-000000000001"
            workspace.selectedTabID = selectedTabID
            workspace.focusedPaneID = focusedPaneID
            workspaces = [workspace]; selectedWorkspaceID = workspace.id
            for index in tabs.indices { tabs[index].workspaceID = workspace.id }
        }
        rememberSelection()
    }

    private mutating func rememberSelection() {
        if let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }) {
            workspaces[index].selectedTabID = selectedTabID
            workspaces[index].focusedPaneID = focusedPaneID
        }
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs[index].panes.contains(focusedPaneID ?? "") {
            tabs[index].focusedPaneID = focusedPaneID
        }
    }

    @discardableResult public mutating func addWorkspace(title: String) -> String {
        rememberSelection()
        let workspace = WorkspaceRecord(title: title)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id; selectedTabID = nil; focusedPaneID = nil
        return workspace.id
    }

    static func normalizedSessionTitle(_ title: String?) throws -> String? {
        let value = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 200, value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw TerminalError.invalid("Session names must be at most 200 characters without control characters")
        }
        return value.isEmpty ? nil : value
    }

    func workspace(named title: String) -> WorkspaceRecord? {
        workspaces.first {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(title) == .orderedSame
        }
    }

    func nextSessionTitle() -> String {
        var number = 1
        while workspace(named: "Session \(number)") != nil { number += 1 }
        return "Session \(number)"
    }

    public mutating func selectWorkspace(_ id: String) throws {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown workspace") }
        rememberSelection()
        let workspace = workspaces[index]
        workspaces[index].closed = false
        selectedWorkspaceID = id
        let available = currentTabs
        let tab = available.first { $0.id == workspace.selectedTabID } ?? available.first
        selectedTabID = tab?.id
        focusedPaneID = tab?.panes.contains(workspace.focusedPaneID ?? "") == true ? workspace.focusedPaneID : tab?.focusedPaneID ?? tab?.panes.first
        rememberSelection()
    }

    public mutating func selectTab(_ id: String) throws {
        guard let tab = tabs.first(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown tab") }
        rememberSelection()
        selectedWorkspaceID = tab.workspaceID
        if let index = workspaces.firstIndex(where: { $0.id == tab.workspaceID }) { workspaces[index].closed = false }
        selectedTabID = id
        focusedPaneID = tab.panes.contains(tab.focusedPaneID ?? "") ? tab.focusedPaneID : tab.panes.first
        rememberSelection()
    }

    public mutating func focusPane(_ id: String) throws {
        guard let tab = tabs.first(where: { $0.panes.contains(id) }) else { throw TerminalError.invalid("Unknown attached pane") }
        if tab.id != selectedTabID { try selectTab(tab.id) }
        focusedPaneID = id
        rememberSelection()
    }

    public mutating func cycleWorkspace(_ delta: Int) {
        let available = workspaces.filter { !$0.closed }
        guard !available.isEmpty else { return }
        let index = available.firstIndex { $0.id == selectedWorkspaceID } ?? 0
        try? selectWorkspace(available[(index + delta % available.count + available.count) % available.count].id)
    }

    public mutating func cycleTab(_ delta: Int) {
        let available = currentTabs
        guard !available.isEmpty else { return }
        let index = available.firstIndex { $0.id == selectedTabID } ?? 0
        try? selectTab(available[(index + delta % available.count + available.count) % available.count].id)
    }

    @discardableResult public mutating func addTab(paneID: String) -> String {
        if let tab = tabs.first(where: { $0.panes.contains(paneID) }) { try? focusPane(paneID); return tab.id }
        if !workspaces.contains(where: { $0.id == selectedWorkspaceID }) { addWorkspace(title: "Workspace") }
        rememberSelection()
        var tab = TerminalTab(paneID: paneID)
        tab.workspaceID = selectedWorkspaceID
        tabs.append(tab)
        selectedTabID = tab.id; focusedPaneID = paneID
        rememberSelection()
        return tab.id
    }

    public mutating func split(tabID: String, paneID: String, axis: SplitAxis, before: Bool = false) throws {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { throw TerminalError.invalid("Unknown tab") }
        guard !tabs.contains(where: { $0.panes.contains(paneID) }) else { throw TerminalError.invalid("Pane already attached") }
        let target = tabs[index].panes.contains(focusedPaneID ?? "") ? focusedPaneID! : tabs[index].panes.last!
        tabs[index].tree = tabs[index].tree.inserting(paneID, beside: target, axis: axis)
        if before { tabs[index].tree = tabs[index].tree.swapping(target, paneID) }
        try focusPane(paneID)
    }

    public mutating func resize(splitID: String, ratio: Double) throws {
        guard ratio.isFinite, let index = tabs.firstIndex(where: { $0.tree.ratio(for: splitID) != nil }) else { throw TerminalError.invalid("Unknown split or invalid ratio") }
        tabs[index].tree = tabs[index].tree.resizing(splitID, ratio: ratio)
    }

    public mutating func move(paneID: String, to target: String) throws {
        guard tabs.contains(where: { $0.id == target }), let source = tabs.first(where: { $0.panes.contains(paneID) }) else { throw TerminalError.invalid("Unknown pane or destination tab") }
        if source.id == target { return }
        detach(paneID)
        let index = tabs.firstIndex(where: { $0.id == target })!
        tabs[index].tree = tabs[index].tree.inserting(paneID, beside: tabs[index].panes.last!, axis: .horizontal)
        try focusPane(paneID)
    }

    public mutating func detach(_ paneID: String) {
        tabs = tabs.compactMap { tab in
            guard let tree = tab.tree.removing(paneID) else { return nil }
            var next = tab; next.tree = tree
            if !tree.panes.contains(next.focusedPaneID ?? "") { next.focusedPaneID = tree.panes.first }
            return next
        }
        repairSelection()
    }

    public mutating func forget(_ paneID: String) {
        detach(paneID)
        closedTabs = closedTabs.compactMap { tab in
            guard let tree = tab.tree.removing(paneID) else { return nil }
            var next = tab; next.tree = tree
            if !tree.panes.contains(next.focusedPaneID ?? "") { next.focusedPaneID = tree.panes.first }
            return next
        }
    }

    private mutating func repairSelection() {
        let tab = currentTabs.first { $0.id == selectedTabID } ?? currentTabs.first
        selectedTabID = tab?.id
        if !(tab?.panes.contains(focusedPaneID ?? "") ?? false) { focusedPaneID = tab?.focusedPaneID ?? tab?.panes.first }
        rememberSelection()
    }

    public mutating func closeTab(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        rememberSelection()
        closedTabs.append(tabs.remove(at: index))
        if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
        repairSelection()
    }

    public mutating func restoreTab() {
        guard var tab = closedTabs.popLast() else { return }
        var tree: PaneTree? = tab.tree
        for id in tabs.flatMap(\.panes) { tree = tree?.removing(id) }
        guard let tree else { return }
        tab.tree = tree
        if !workspaces.contains(where: { $0.id == tab.workspaceID }) { tab.workspaceID = addWorkspace(title: "Restored") }
        tabs.append(tab)
        try? selectTab(tab.id)
    }

    public mutating func reorderTab(_ id: String, delta: Int) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let neighbors = tabs.filter { $0.workspaceID == tab.workspaceID }
        guard let current = neighbors.firstIndex(where: { $0.id == id }), neighbors.indices.contains(current + delta),
              let first = tabs.firstIndex(where: { $0.id == id }), let second = tabs.firstIndex(where: { $0.id == neighbors[current + delta].id }) else { return }
        tabs.swapAt(first, second)
    }

    public mutating func closeWorkspace(_ id: String) {
        rememberSelection()
        if let index = workspaces.firstIndex(where: { $0.id == id }) { workspaces[index].closed = true }
        if selectedWorkspaceID == id {
            if let next = workspaces.first(where: { !$0.closed }) { try? selectWorkspace(next.id) }
            else { selectedWorkspaceID = nil; selectedTabID = nil; focusedPaneID = nil }
        }
    }
}

extension PaneTree {
    func swapping(_ firstID: String, _ secondID: String) -> PaneTree {
        switch self {
        case .pane(let id): return .pane(id == firstID ? secondID : id == secondID ? firstID : id)
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: ratio, first: first.swapping(firstID, secondID), second: second.swapping(firstID, secondID))
        }
    }
    public var balanced: PaneTree {
        switch self {
        case .pane: return self
        case .split(let id, let axis, _, let first, let second): return .split(id: id, axis: axis, ratio: 0.5, first: first.balanced, second: second.balanced)
        }
    }
}

public enum PathInsertion {
    public static func text(paths: [String]) throws -> String {
        guard !paths.isEmpty, paths.count <= 100,
              paths.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0") }) else {
            throw TerminalError.invalid("Select paths without newline or NUL characters")
        }
        return paths.map(ShellQuote.quote).joined(separator: " ") + " "
    }
}
