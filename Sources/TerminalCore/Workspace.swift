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
    /// Derived from `master-view.json` and session activity when state is read; not part of the stored layout.
    public var masterView: MasterViewProjection?
    public var currentTabs: [TerminalTab] {
        let own = tabs.filter { $0.workspaceID == selectedWorkspaceID }
        guard let presented = presentedTabIDs, !presented.isEmpty else { return own }
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return own + presented.compactMap { byID[$0] }
    }
    /// Tabs of other workspaces shown in the selected workspace because it is the Master View.
    public var presentedTabIDs: [String]? {
        guard let masterView, masterView.workspaceID == selectedWorkspaceID else { return nil }
        return masterView.tabIDs
    }
    public func isPresentedInMasterView(_ tabID: String) -> Bool { presentedTabIDs?.contains(tabID) == true }
    /// Tabs whose workspace is open; tabs of a closed workspace stay retained but are not presented.
    public var openTabs: [TerminalTab] {
        let closed = Set(workspaces.filter(\.closed).map(\.id))
        return tabs.filter { $0.workspaceID.map { !closed.contains($0) } ?? true }
    }
    /// Panes whose only placements are retained closed tabs or closed-workspace tabs; they need an explicit reopen.
    /// A split-close snapshot keeps its still-open siblings, so only its focused pane counts while that tab exists.
    public var closedPaneIDs: Set<String> {
        let open = Set(openTabs.flatMap(\.panes))
        let liveTabIDs = Set(tabs.map(\.id))
        var closed = Set(tabs.flatMap(\.panes))
        for snapshot in closedTabs {
            if liveTabIDs.contains(snapshot.id) { if let pane = snapshot.focusedPaneID { closed.insert(pane) } }
            else { closed.formUnion(snapshot.panes) }
        }
        return closed.subtracting(open)
    }
    public func isClosedPane(_ paneID: String) -> Bool { closedPaneIDs.contains(paneID) }
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
        if !isPresentedInMasterView(id) {
            selectedWorkspaceID = tab.workspaceID
            if let index = workspaces.firstIndex(where: { $0.id == tab.workspaceID }) { workspaces[index].closed = false }
        }
        selectedTabID = id
        focusedPaneID = tab.panes.contains(tab.focusedPaneID ?? "") ? tab.focusedPaneID : tab.panes.first
        rememberSelection()
    }

    /// Selects a tab the caller saw presented in the Master View. Membership is not re-derived here: reading the tab can
    /// remove it from the projection before this commits. Falls back to an ordinary selection once the view is gone.
    public mutating func selectPresentedTab(_ id: String) throws {
        guard let tab = tabs.first(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown tab") }
        guard let master = masterView?.workspaceID, selectedWorkspaceID == master, tab.workspaceID != master,
              workspaces.contains(where: { $0.id == tab.workspaceID && !$0.closed }) else { return try selectTab(id) }
        rememberSelection()
        if masterView?.tabIDs.contains(id) == false { masterView?.tabIDs.append(id) }
        selectedTabID = id
        focusedPaneID = tab.panes.contains(tab.focusedPaneID ?? "") ? tab.focusedPaneID : tab.panes.first
        rememberSelection()
    }

    /// A selected tab of another workspace that the Master View no longer presents gives way to a tab the view shows.
    mutating func repairPresentedSelection() {
        guard let id = selectedTabID, let tab = tabs.first(where: { $0.id == id }), tab.workspaceID != selectedWorkspaceID,
              !isPresentedInMasterView(id), workspaces.contains(where: { $0.id == selectedWorkspaceID }) else { return }
        repairSelection()
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
        if !workspaces.contains(where: { $0.id == selectedWorkspaceID }) { addWorkspace(title: randomWorkspaceTitle()) }
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
        let tab = tabs.remove(at: index)
        rememberClosedTab(tab)
        if let workspaceID = tab.workspaceID, workspaceID != masterView?.workspaceID, !tabs.contains(where: { $0.workspaceID == workspaceID }) {
            closeWorkspace(workspaceID)
            if selectedWorkspaceID != nil, !currentTabs.contains(where: { $0.id == selectedTabID }) { repairSelection() }
        } else { repairSelection() }
    }

    public mutating func closePane(_ id: String) {
        guard let tab = tabs.first(where: { $0.panes.contains(id) }) else { return }
        if tab.panes.count == 1 { closeTab(tab.id) }
        else {
            var snapshot = tab
            snapshot.focusedPaneID = id
            rememberClosedTab(snapshot)
            detach(id)
        }
    }

    private mutating func rememberClosedTab(_ tab: TerminalTab) {
        closedTabs.append(tab)
        if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
    }

    public mutating func restoreTab() {
        while var tab = closedTabs.popLast() {
            let attached = Set(tabs.flatMap(\.panes))
            if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                if let workspace = tab.workspaceID, tabs[index].workspaceID == workspace,
                   workspaces.contains(where: { $0.id == workspace && $0.closed }),
                   let pane = tab.focusedPaneID, tabs[index].panes.contains(pane) {
                    try? selectTab(tab.id)
                    try? focusPane(pane)
                    return
                }
                guard let pane = tab.focusedPaneID, !attached.contains(pane), tab.panes.contains(pane) else { continue }
                if var placement = tab.tree.restorationPlacement(for: pane, available: Set(tabs[index].panes)) {
                    if tabs.contains(where: { $0.tree.ratio(for: placement.splitID) != nil }) { placement.splitID = UUID().uuidString }
                    tabs[index].tree = tabs[index].tree.restoringPane(pane, at: placement)
                } else if let anchor = tabs[index].panes.last {
                    tabs[index].tree = tabs[index].tree.inserting(pane, beside: anchor, axis: .horizontal)
                }
                try? focusPane(pane)
                return
            }
            var tree: PaneTree? = tab.tree
            for id in attached { tree = tree?.removing(id) }
            guard let tree else { continue }
            tab.tree = tree
            if !workspaces.contains(where: { $0.id == tab.workspaceID }) { tab.workspaceID = addWorkspace(title: "Restored") }
            tabs.append(tab)
            try? selectTab(tab.id)
            return
        }
    }

    public mutating func reorderTab(_ id: String, delta: Int) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let neighbors = tabs.filter { $0.workspaceID == tab.workspaceID }
        guard let current = neighbors.firstIndex(where: { $0.id == id }), neighbors.indices.contains(current + delta),
              let first = tabs.firstIndex(where: { $0.id == id }), let second = tabs.firstIndex(where: { $0.id == neighbors[current + delta].id }) else { return }
        tabs.swapAt(first, second)
    }

    public mutating func reorderWorkspace(_ id: String, delta: Int) throws {
        guard delta == -1 || delta == 1 else { throw TerminalError.invalid("Workspace reorder delta must be -1 or 1") }
        guard let index = workspaces.firstIndex(where: { $0.id == id }), !workspaces[index].closed else {
            throw TerminalError.invalid("Unknown or closed workspace")
        }
        let openIndices = workspaces.indices.filter { !workspaces[$0].closed }
        guard let position = openIndices.firstIndex(of: index), openIndices.indices.contains(position + delta) else { return }
        workspaces.swapAt(index, openIndices[position + delta])
    }

    public mutating func closeWorkspace(_ id: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), !workspaces[index].closed else { return }
        rememberSelection()
        let selected = workspaces[index].selectedTabID
        if var snapshot = tabs.first(where: { $0.workspaceID == id && $0.id == selected }) ?? tabs.first(where: { $0.workspaceID == id }) {
            if let focus = workspaces[index].focusedPaneID, snapshot.panes.contains(focus) { snapshot.focusedPaneID = focus }
            else if !snapshot.panes.contains(snapshot.focusedPaneID ?? "") { snapshot.focusedPaneID = snapshot.panes.first }
            rememberClosedTab(snapshot)
        }
        workspaces[index].closed = true
        if selectedWorkspaceID == id {
            if let next = nextOpenWorkspace(after: id) { try? selectWorkspace(next.id) }
            else { selectedWorkspaceID = nil; selectedTabID = nil; focusedPaneID = nil }
        }
    }

    func nextOpenWorkspace(after id: String) -> WorkspaceRecord? {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return workspaces.first { !$0.closed } }
        for offset in 1...workspaces.count {
            let next = workspaces[(index + offset) % workspaces.count]
            if !next.closed { return next }
        }
        return nil
    }
}

private typealias PaneRestorationPlacement = (splitID: String, axis: SplitAxis, ratio: Double, before: Bool, anchors: Set<String>)

private extension PaneTree {
    func restorationPlacement(for paneID: String, available: Set<String>) -> PaneRestorationPlacement? {
        guard case .split(let id, let axis, let ratio, let first, let second) = self else { return nil }
        let before = first.panes.contains(paneID)
        guard before || second.panes.contains(paneID) else { return nil }
        let branch = before ? first : second
        if let deeper = branch.restorationPlacement(for: paneID, available: available) { return deeper }
        let anchors = Set((before ? second : first).panes).intersection(available)
        return anchors.isEmpty ? nil : (id, axis, ratio, before, anchors)
    }

    func restoringPane(_ paneID: String, at placement: PaneRestorationPlacement) -> PaneTree {
        if case .split(let id, let axis, let ratio, let first, let second) = self {
            if placement.anchors.isSubset(of: Set(first.panes)) {
                return .split(id: id, axis: axis, ratio: ratio, first: first.restoringPane(paneID, at: placement), second: second)
            }
            if placement.anchors.isSubset(of: Set(second.panes)) {
                return .split(id: id, axis: axis, ratio: ratio, first: first, second: second.restoringPane(paneID, at: placement))
            }
        }
        return .split(id: placement.splitID, axis: placement.axis, ratio: placement.ratio,
                      first: placement.before ? .pane(paneID) : self, second: placement.before ? self : .pane(paneID))
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

public enum TabSide: Sendable { case left, right }

extension WorkspaceLayout {
    /// Tabs of the same workspace on one side of `id`, in strip order.
    public func tabIDs(beside id: String, side: TabSide) -> [String] {
        guard let tab = tabs.first(where: { $0.id == id }) else { return [] }
        let row = tabs.filter { $0.workspaceID == tab.workspaceID }
        guard let index = row.firstIndex(where: { $0.id == id }) else { return [] }
        return (side == .left ? Array(row[..<index]) : Array(row[(index + 1)...])).map(\.id)
    }
}
