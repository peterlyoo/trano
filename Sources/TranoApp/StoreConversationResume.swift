import AppKit
import Foundation
import TerminalCore

final class ConversationResumeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

extension AppStore {
    func toggleConversationResume(owner proposedOwner: NSWindow? = nil) {
        if conversationResume != nil { dismissConversationResume(); return }
        guard externalPanePolicy == nil, safeInterfaceNavigation,
              let sourceWindow = proposedOwner ?? NSApp.keyWindow,
              sourceWindow.isVisible, sourceWindow.isKeyWindow, NSApp.isActive,
              let owner = floatingPanes.presentationOwner(for: sourceWindow),
              owner.attachedSheet == nil,
              (owner.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
        guard isActiveWindow() || terminalViews.values.contains(where: { $0.window === sourceWindow }) else { return }
        if owner !== sourceWindow {
            if owner.isMiniaturized { owner.deminiaturize(nil) }
            owner.makeKeyAndOrderFront(nil)
        }
        guard owner.isVisible, owner.isKeyWindow else { return }
        commandKeyHints.cancel()
        showActivity = false
        let lease = ConversationResumeCancellation()
        conversationResumeLease = lease
        conversationResumeOwner = owner
        let workspaceID = preferredWorkspaceID
        let runtime = runtime, queue = queue
        let model = ConversationResumeModel(load: { [weak self] completion in
            queue.async {
                let result = Result { () -> ConversationHistorySnapshot in
                    let sources = try runtime.conversationHistorySources()
                    return ConversationHistoryIndex.discover(sources: sources, cancelled: { lease.isCancelled })
                }
                let context = try? runtime.conversationResumeContext()
                DispatchQueue.main.async { [weak self] in
                    if let self, self.conversationResumeLease === lease, !lease.isCancelled,
                       let snapshot = try? result.get(), let context {
                        self.conversationResumeLivePanes = Dictionary(snapshot.conversations.compactMap { entry in
                            ConversationResumeCoordinator.livePane(for: entry, context: context).map { (entry.id, $0) }
                        }, uniquingKeysWith: { first, _ in first })
                    }
                    completion(result)
                }
            }
        }, onActivate: { [weak self] entry in
            guard let self, self.conversationResumeLease === lease, let model = self.conversationResume else { return }
            self.activateConversation(entry, model: model, lease: lease, workspaceID: workspaceID)
        }, livePaneIDs: { [weak self] in self?.conversationResumeLivePanes ?? [:] },
           canInteract: { [weak self, weak owner] in self?.canInteractWithConversationResume(owner: owner, lease: lease) == true },
           hasMarkedText: { [weak owner] in (owner?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true })
        conversationResume = model
        for view in terminalViews.values { view.invalidateTerminalInteractions() }
        model.refresh()
    }

    @discardableResult func dismissConversationResume() -> Bool {
        guard let model = conversationResume,
              (conversationResumeOwner?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
              model.dismiss() else { return false }
        conversationResumeLease?.cancel()
        conversationResume = nil
        conversationResumeLease = nil
        conversationResumeOwner = nil
        conversationResumeLivePanes = [:]
        restoreTerminalFocus()
        return true
    }

    func cancelConversationResumeForWindowClosure(_ window: NSWindow) {
        guard conversationResumeOwner === window else { return }
        conversationResumeLease?.cancel()
        _ = conversationResume?.dismiss()
        conversationResume = nil
        conversationResumeLease = nil
        conversationResumeOwner = nil
        conversationResumeLivePanes = [:]
    }

    private func canInteractWithConversationResume(owner: NSWindow?, lease: ConversationResumeCancellation) -> Bool {
        guard conversationResumeLease === lease, !lease.isCancelled,
              let owner, owner === conversationResumeOwner, owner.isVisible, !owner.isMiniaturized,
              owner.isKeyWindow, NSApp.isActive, owner.attachedSheet == nil, NSApp.modalWindow == nil,
              decisionPaneID == nil, followUpPaneID == nil, picker == nil,
              !showSettings, !showVoice, !showRemoteHosts, !showAccounts, !showExtensions, remotePathRequest == nil else { return false }
        return (owner.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }

    private func activateConversation(_ entry: AgentConversation, model: ConversationResumeModel,
                                      lease: ConversationResumeCancellation, workspaceID: String?) {
        let runtime = runtime
        queue.async { [weak self, weak model] in
            let allowed = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let self, let model, self.conversationResume === model,
                          self.preferredWorkspaceID == workspaceID else { return false }
                    return self.canInteractWithConversationResume(owner: self.conversationResumeOwner, lease: lease)
                }
            }
            let result = Result { () -> ConversationResumeOutcome in
                guard allowed, !lease.isCancelled else { throw TerminalError.invalid("The Resume window changed. Select the conversation again.") }
                return try runtime.resumeConversation(entry, workspaceID: workspaceID, isCancelled: { lease.isCancelled })
            }
            DispatchQueue.main.async { [weak self, weak model] in
                guard let self, let model, self.conversationResume === model, self.conversationResumeLease === lease else { return }
                switch result {
                case .failure(let error): model.finishActivation(error: error)
                case .success(let outcome):
                    model.finishActivation(error: nil)
                    if (self.conversationResumeOwner?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return }
                    let presentingOwner = self.conversationResumeOwner
                    guard self.dismissConversationResume() else { return }
                    self.floatingPanes.suppressOwnerReturnFocus()
                    if outcome.supervisor || outcome.unisession { self.onRevealSupervisor?() }
                    else if outcome.existing, let owner = WorkspaceOwners.floatingOwner(paneID: outcome.paneID, root: runtime.root) {
                        owner.floatingPanes.focus(outcome.paneID)
                    } else {
                        presentingOwner?.makeKeyAndOrderFront(nil)
                        self.attach(outcome.paneID)
                    }
                }
            }
        }
    }
}
