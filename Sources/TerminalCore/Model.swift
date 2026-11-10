import Foundation

public enum ActivityState: String, Codable, CaseIterable { case unknown, idle, running, blocked, done, error }
public enum AgentKind: String, Codable, CaseIterable { case shell, claude, codex }
public enum SplitAxis: String, Codable { case horizontal, vertical }

public struct Activity: Codable, Equatable {
    public var state: ActivityState = .unknown
    public var reason: String = ""
    public var source: String = "unknown"
    public var updatedAt: Date = Date()
    public init() {}
}

public struct AgentTask: Codable, Equatable, Identifiable {
    public var id: String
    public var parentID: String?
    public var name: String
    public var agent: AgentKind
    public var activity: Activity
    public var generation: String?

    public init(id: String, parentID: String? = nil, name: String, agent: AgentKind,
                activity: Activity = Activity(), generation: String? = nil) {
        self.id = id; self.parentID = parentID; self.name = name
        self.agent = agent; self.activity = activity; self.generation = generation
    }
}

public struct TerminalSession: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var cwd: String
    public var pid: Int32
    public var host: String = "local"
    public var agent: AgentKind = .shell
    public var activity = Activity()
    public var createdAt = Date()
    public var alive = true
    public var remote: RemoteReference?
    public var agentTasks: [AgentTask]?
}

public indirect enum PaneTree: Codable, Equatable {
    case pane(String)
    case split(id: String, axis: SplitAxis, ratio: Double, first: PaneTree, second: PaneTree)

    public var panes: [String] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, _, let first, let second): return first.panes + second.panes
        }
    }

    public func ratio(for splitID: String) -> Double? {
        switch self {
        case .pane: return nil
        case .split(let id, _, let ratio, let first, let second):
            return id == splitID ? ratio : first.ratio(for: splitID) ?? second.ratio(for: splitID)
        }
    }

    public func parent(of paneID: String) -> String? {
        switch self {
        case .pane: return nil
        case .split(let id, _, _, let first, let second):
            if first == .pane(paneID) || second == .pane(paneID) { return id }
            return first.parent(of: paneID) ?? second.parent(of: paneID)
        }
    }

    func inserting(_ paneID: String, beside target: String, axis: SplitAxis) -> PaneTree {
        switch self {
        case .pane(let id):
            return id == target ? .split(id: UUID().uuidString, axis: axis, ratio: 0.5, first: self, second: .pane(paneID)) : self
        case .split(let id, let direction, let ratio, let first, let second):
            return .split(id: id, axis: direction, ratio: ratio,
                          first: first.inserting(paneID, beside: target, axis: axis),
                          second: second.inserting(paneID, beside: target, axis: axis))
        }
    }

    func removing(_ paneID: String) -> PaneTree? {
        switch self {
        case .pane(let id): return id == paneID ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            let left = first.removing(paneID), right = second.removing(paneID)
            guard let left else { return right }
            guard let right else { return left }
            return .split(id: id, axis: axis, ratio: ratio, first: left, second: right)
        }
    }

    func resizing(_ splitID: String, ratio: Double) -> PaneTree {
        switch self {
        case .pane: return self
        case .split(let id, let axis, let previous, let first, let second):
            return .split(id: id, axis: axis, ratio: id == splitID ? min(0.85, max(0.15, ratio)) : previous,
                          first: first.resizing(splitID, ratio: ratio), second: second.resizing(splitID, ratio: ratio))
        }
    }
}

public struct TerminalTab: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString.lowercased()
    public var title = "Terminal"
    public var tree: PaneTree
    public var workspaceID: String?
    public var focusedPaneID: String?
    public var panes: [String] { tree.panes }
    init(paneID: String) { tree = .pane(paneID); focusedPaneID = paneID }

    private enum CodingKeys: String, CodingKey { case id, title, tree, panes, axis, workspaceID, focusedPaneID }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        title = try box.decode(String.self, forKey: .title)
        workspaceID = try box.decodeIfPresent(String.self, forKey: .workspaceID)
        focusedPaneID = try box.decodeIfPresent(String.self, forKey: .focusedPaneID)
        if let value = try box.decodeIfPresent(PaneTree.self, forKey: .tree) { tree = value }
        else {
            let panes = try box.decode([String].self, forKey: .panes)
            guard let first = panes.first else { throw TerminalError.invalid("Empty tab") }
            let axis = try box.decodeIfPresent(SplitAxis.self, forKey: .axis) ?? .horizontal
            tree = panes.dropFirst().reduce(.pane(first)) { tree, id in tree.inserting(id, beside: tree.panes.last!, axis: axis) }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(title, forKey: .title)
        try box.encode(tree, forKey: .tree)
        try box.encode(panes, forKey: .panes)
        try box.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try box.encodeIfPresent(focusedPaneID, forKey: .focusedPaneID)
    }
}

public struct TerminalSettings: Codable, Equatable {
    public var fontName = "SFMono-Regular"
    public var fontSize: Double = 14
    public var background = "#0B0B0C"
    public var notifications = true
    public var scrollbackLines = 10_000
    public var optionAsMeta: Bool? = false
    public var persistScrollback = true
    public var automaticRestore = true
    public var automaticAccountSwitching = false
    public var appearance = AppearancePreferences()
    public var appearanceProfiles: [AppearanceProfile] = []
    public var paneAppearanceProfiles: [String: String] = [:]
    public var keyBindings: [String: [String]] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey { case persistScrollback, fontName, fontSize, background, notifications, scrollbackLines, optionAsMeta, automaticRestore, automaticAccountSwitching, appearance, appearanceProfiles, paneAppearanceProfiles, keyBindings }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try box.decodeIfPresent(String.self, forKey: .fontName) ?? "SFMono-Regular"
        fontSize = min(40, max(9, try box.decodeIfPresent(Double.self, forKey: .fontSize) ?? 14))
        background = try box.decodeIfPresent(String.self, forKey: .background) ?? "#0B0B0C"
        notifications = try box.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        scrollbackLines = min(100_000, max(1000, try box.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? 10_000))
        optionAsMeta = try box.decodeIfPresent(Bool.self, forKey: .optionAsMeta) ?? false
        persistScrollback = try box.decodeIfPresent(Bool.self, forKey: .persistScrollback) ?? true
        automaticRestore = try box.decodeIfPresent(Bool.self, forKey: .automaticRestore) ?? true
        automaticAccountSwitching = try box.decodeIfPresent(Bool.self, forKey: .automaticAccountSwitching) ?? false
        appearance = try box.decodeIfPresent(AppearancePreferences.self, forKey: .appearance) ?? AppearancePreferences()
        appearanceProfiles = try box.decodeIfPresent([AppearanceProfile].self, forKey: .appearanceProfiles) ?? []
        paneAppearanceProfiles = try box.decodeIfPresent([String: String].self, forKey: .paneAppearanceProfiles) ?? [:]
        keyBindings = try box.decodeIfPresent([String: [String]].self, forKey: .keyBindings) ?? [:]
    }
    public mutating func merge(_ draft: TerminalSettings, from baseline: TerminalSettings) {
        if draft.fontName != baseline.fontName { fontName = draft.fontName }
        if draft.fontSize != baseline.fontSize { fontSize = draft.fontSize }
        if draft.background != baseline.background { background = draft.background }
        if draft.notifications != baseline.notifications { notifications = draft.notifications }
        if draft.scrollbackLines != baseline.scrollbackLines { scrollbackLines = draft.scrollbackLines }
        if draft.optionAsMeta != baseline.optionAsMeta { optionAsMeta = draft.optionAsMeta }
        if draft.persistScrollback != baseline.persistScrollback { persistScrollback = draft.persistScrollback }
        if draft.automaticRestore != baseline.automaticRestore { automaticRestore = draft.automaticRestore }
        if draft.automaticAccountSwitching != baseline.automaticAccountSwitching { automaticAccountSwitching = draft.automaticAccountSwitching }
        if draft.appearance != baseline.appearance { appearance = draft.appearance }
        if draft.appearanceProfiles != baseline.appearanceProfiles { appearanceProfiles = draft.appearanceProfiles }
        if draft.paneAppearanceProfiles != baseline.paneAppearanceProfiles { paneAppearanceProfiles = draft.paneAppearanceProfiles }
        if draft.keyBindings != baseline.keyBindings { keyBindings = draft.keyBindings }
    }
}

public struct RuntimeState: Codable {
    public var schemaVersion = 1
    public var sessions: [TerminalSession] = []
    public var layout = WorkspaceLayout()
    public var settings = TerminalSettings()
    public var revision = 0
    public var events: [ActivityEvent] = []
    public var eventsDiscardedThrough = 0
    public var navigationRequest: NavigationRequest?
    public var remoteHosts: [RemoteHost] = []
    public var accounts: [AccountProfile] = []
    public var extensions: [ManagedExtension] = []
    public var agentLaunches: [AgentLaunch] = []
    public var recoveryResults: [RecoveryResult] = []
    public var supervision: [AgentSupervision] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case schemaVersion, sessions, layout, settings, revision, events, eventsDiscardedThrough, navigationRequest, remoteHosts, accounts, extensions, agentLaunches, recoveryResults, supervision }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decode(Int.self, forKey: .schemaVersion)
        sessions = try box.decode([TerminalSession].self, forKey: .sessions)
        layout = try box.decode(WorkspaceLayout.self, forKey: .layout)
        settings = try box.decode(TerminalSettings.self, forKey: .settings)
        revision = try box.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        events = try box.decodeIfPresent([ActivityEvent].self, forKey: .events) ?? []
        eventsDiscardedThrough = try box.decodeIfPresent(Int.self, forKey: .eventsDiscardedThrough) ?? 0
        navigationRequest = try box.decodeIfPresent(NavigationRequest.self, forKey: .navigationRequest)
        remoteHosts = try box.decodeIfPresent([RemoteHost].self, forKey: .remoteHosts) ?? []
        accounts = try box.decodeIfPresent([AccountProfile].self, forKey: .accounts) ?? []
        extensions = try box.decodeIfPresent([ManagedExtension].self, forKey: .extensions) ?? []
        agentLaunches = try box.decodeIfPresent([AgentLaunch].self, forKey: .agentLaunches) ?? []
        recoveryResults = try box.decodeIfPresent([RecoveryResult].self, forKey: .recoveryResults) ?? []
        supervision = try box.decodeIfPresent([AgentSupervision].self, forKey: .supervision) ?? []
    }
}

public enum TerminalError: Error, LocalizedError {
    case invalid(String), runtime(String)
    public var errorDescription: String? {
        switch self { case .invalid(let text), .runtime(let text): return text }
    }
}
