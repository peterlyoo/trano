import AppKit
import SwiftUI
import TerminalCore

enum WorktreeCleanupPresentation {
    static func title(_ status: WorktreeCleanupStatus) -> String {
        switch status {
        case .tracked: return "Waiting for Task Completion"
        case .pending: return "Cleanup Scheduled"
        case .held: return "On Hold"
        case .removing: return "Cleaning Up…"
        case .removed: return "Cleaned Up"
        case .needsReview: return "Review Needed"
        case .error: return "Cleanup Failed"
        }
    }
    static func canRetry(status: WorktreeCleanupStatus, completed: Bool, enabled: Bool) -> Bool {
        enabled && completed && [.held, .error].contains(status)
    }
}

struct WorktreeCleanupSection: View {
    @ObservedObject var store: AppStore
    private var records: [WorktreeCleanupRecord] { Array(store.worktreeCleanupRecords.sorted { $0.updatedAt > $1.updatedAt }.prefix(20)) }
    var body: some View {
        if !records.isEmpty || store.worktreeCleanupError != nil || store.worktreeCleanupActionError != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Worktrees").font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text(store.integrationsPreferences.automaticallyCleanWorktrees ? "Auto Cleanup" : "Cleanup Off")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let error = store.worktreeCleanupActionError ?? store.worktreeCleanupError { Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2) }
                ForEach(records, id: \.id) { record in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: record.status == .removed ? "checkmark.circle" : "arrow.triangle.branch")
                            .frame(width: 18).foregroundStyle(record.status == .removed ? Color.secondary : Color.primary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(URL(fileURLWithPath: record.path).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).help(record.path)
                            Text(WorktreeCleanupPresentation.title(record.status)).font(.system(size: 10)).foregroundStyle(.secondary)
                            if let message = record.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3) }
                            HStack(spacing: 10) {
                                if WorktreeCleanupPresentation.canRetry(status: record.status, completed: record.completion != nil, enabled: store.integrationsPreferences.automaticallyCleanWorktrees) {
                                    Button("Retry") { store.retryWorktreeCleanup(record) }
                                }
                                if ![.removed, .removing, .needsReview].contains(record.status) {
                                    Button("Keep Worktree") { store.keepWorktree(record) }
                                }
                                if record.status != .removed {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.path)]) } label: { Image(systemName: "folder") }
                                        .help("Show Worktree in Finder")
                                }
                            }.font(.system(size: 10)).buttonStyle(.borderless).disabled(store.worktreeCleanupBusy.contains(record.id))
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 5)
                }
            }
        }
    }
}
