import Foundation
import TerminalCore

extension AppStore {
    func reloadWorktreeCleanup() {
        guard externalPanePolicy == nil else { return }
        let runtime = runtime
        queue.async { [weak self] in
            do {
                let records = try WorktreeCleanupStore(root: runtime.root).load().records
                let trackingAvailable = GitTrackingShell.isInstalled(root: runtime.root)
                let enabled = try runtime.integrationsPreferences().automaticallyCleanWorktrees
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.worktreeCleanupRecords != records { self.worktreeCleanupRecords = records }
                    self.worktreeCleanupError = enabled && !trackingAvailable ? "Worktree tracking is unavailable. New worktrees will be kept." : nil
                }
            } catch {
                DispatchQueue.main.async { self?.worktreeCleanupError = error.localizedDescription }
            }
        }
    }
    func retryWorktreeCleanup(_ record: WorktreeCleanupRecord) {
        mutateWorktree(record) { try $0.worktreeCleanupCoordinator().retry(id: record.id) }
    }
    func keepWorktree(_ record: WorktreeCleanupRecord) {
        mutateWorktree(record) { try $0.keepWorktree(id: record.id, expectedUpdatedAt: record.updatedAt) }
    }
    private func mutateWorktree(_ record: WorktreeCleanupRecord, work: @escaping (TerminalRuntime) throws -> Void) {
        guard !worktreeCleanupBusy.contains(record.id) else { return }
        worktreeCleanupBusy.insert(record.id)
        worktreeCleanupActionError = nil
        let runtime = runtime
        let recordID = record.id
        queue.async { [weak self] in
            let failure: String?
            do { try work(runtime); failure = nil } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                self?.worktreeCleanupBusy.remove(recordID)
                self?.worktreeCleanupActionError = failure
                self?.reloadWorktreeCleanup()
            }
        }
    }
}
