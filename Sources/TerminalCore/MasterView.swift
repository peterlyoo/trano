import Foundation
import Darwin

/// Tabs of other open workspaces presented inside the Master View workspace. Derived on every state read and never persisted.
public struct MasterViewProjection: Equatable {
    public var workspaceID: String
    public var tabIDs: [String]
    public init(workspaceID: String, tabIDs: [String]) { self.workspaceID = workspaceID; self.tabIDs = tabIDs }
}

public enum MasterView {
    /// A session needs review while it waits for a decision or permission, or until a completion or failure has been seen.
    public static func needsReview(_ session: TerminalSession, readAt: Date?) -> Bool {
        session.activity.state == .blocked || ActivityInbox.isUnread(session, readAt: readAt)
    }

    /// Keeps strip order (workspace order, then tab order) so tabs do not jump as their activity changes.
    /// The tab the Master View currently shows stays presented after it has been read.
    public static func projection(layout: WorkspaceLayout, sessions: [TerminalSession], readAt: [String: Date],
                                  workspaceID: String?) -> MasterViewProjection? {
        guard let workspaceID, layout.workspaces.contains(where: { $0.id == workspaceID && !$0.closed }) else { return nil }
        let order = Dictionary(layout.workspaces.enumerated().filter { !$0.element.closed }.map { ($0.element.id, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = layout.selectedWorkspaceID == workspaceID ? layout.selectedTabID
            : layout.workspaces.first(where: { $0.id == workspaceID })?.selectedTabID
        let candidates = layout.tabs.enumerated().filter { _, tab in
            guard let owner = tab.workspaceID, owner != workspaceID, order[owner] != nil else { return false }
            return tab.id == shown || tab.panes.contains { id in byID[id].map { needsReview($0, readAt: readAt[id]) } == true }
        }
        let ids = candidates.sorted {
            let left = order[$0.element.workspaceID!]!, right = order[$1.element.workspaceID!]!
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element.id)
        return MasterViewProjection(workspaceID: workspaceID, tabIDs: ids)
    }
}

private struct MasterViewConfiguration: Codable { var workspaceID: String? }

extension TerminalRuntime {
    private var masterViewURL: URL { root.appendingPathComponent("master-view.json") }

    /// Kept outside state.json and continuity.json: live helpers from an older build rewrite both with their own schema.
    func masterViewData() throws -> Data? {
        let fd = open(masterViewURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw TerminalError.invalid("Cannot open Master View settings") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 4096 else {
            throw TerminalError.invalid("Master View settings must be an owned regular file of at most 4 KiB")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count >= 0 else { throw TerminalError.runtime("Cannot read Master View settings") }
        return Data(bytes.prefix(count))
    }

    func applyMasterView(to state: inout RuntimeState, data: Data?) {
        let workspaceID = data.flatMap { try? JSONDecoder().decode(MasterViewConfiguration.self, from: $0) }?.workspaceID
        state.layout.masterView = MasterView.projection(layout: state.layout, sessions: state.sessions,
                                                        readAt: state.activityReadAt, workspaceID: workspaceID)
        state.layout.repairPresentedSelection()
    }

    public func masterWorkspaceID() throws -> String? {
        try state().layout.masterView?.workspaceID
    }

    /// Designates one open workspace as the Master View, or turns the Master View off with `nil`.
    public func setMasterWorkspace(_ id: String?) throws {
        try update { state in
            if let id, !state.layout.workspaces.contains(where: { $0.id == id && !$0.closed }) {
                throw TerminalError.invalid("Unknown or closed workspace")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try Self.atomicWrite(encoder.encode(MasterViewConfiguration(workspaceID: id)), to: masterViewURL)
            state.layout.masterView = MasterView.projection(layout: state.layout, sessions: state.sessions,
                                                            readAt: state.activityReadAt, workspaceID: id)
            state.layout.repairPresentedSelection()
        }
    }
}
