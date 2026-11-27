import AppKit
import TerminalCore

struct DeferredTerminalUploadTarget: @unchecked Sendable {
    let paneID: String
    let backendPID: Int32
    let remote: RemoteReference?
    let host: RemoteHost?
    let lease: TerminalInteractionLease
    let providerGeneration: String?
    let providerPID: Int32?

    func matches(_ state: RuntimeState) -> Bool {
        guard lease.isValid, lease.owner.paneID == paneID, lease.sessionPID == backendPID,
              lease.hostID == remote?.hostID, host?.id == remote?.hostID,
              let pane = state.sessions.first(where: { $0.id == paneID }), pane.alive,
              pane.pid == backendPID, pane.remote == remote else { return false }
        let launch = state.agentLaunches.first { $0.paneID == paneID && $0.lifecycle == .active }
        guard launch?.id == providerGeneration, launch?.providerPID == providerPID else { return false }
        if let host { return state.remoteHosts.first(where: { $0.id == host.id }) == host }
        return remote == nil
    }
    func save(_ data: Data, runtime: TerminalRuntime, uploader: ((Data, RemoteHost?, RemoteReference?) throws -> String)? = nil) throws -> String {
        guard try runtime.transaction({ matches(try runtime.state()) }) else { throw DeferredTerminalInputError.cancelled }
        let path: String
        if let uploader { path = try uploader(data, host, remote) }
        else if let remote, let host { path = try RemoteClient(host: host).uploadPNG(data, sessionID: remote.sessionID) }
        else { path = try AttachmentStore(root: runtime.root).savePNG(data).path }
        guard try runtime.transaction({ matches(try runtime.state()) }) else { throw DeferredTerminalInputError.cancelled }
        return path
    }
}

enum DeferredTerminalInputError: Error { case cancelled }

@MainActor final class DeferredTerminalInputTarget {
    let attempt: DeferredTerminalInputAttempt
    let upload: DeferredTerminalUploadTarget
    private weak var store: AppStore?
    private weak var renderer: TranoView?
    private weak var window: NSWindow?
    private let applicationActive: () -> Bool

    private init(store: AppStore, renderer: TranoView, window: NSWindow,
                 attempt: DeferredTerminalInputAttempt, upload: DeferredTerminalUploadTarget,
                 applicationActive: @escaping () -> Bool) {
        self.store = store; self.renderer = renderer; self.window = window
        self.attempt = attempt; self.upload = upload; self.applicationActive = applicationActive
    }
    static func capture(store: AppStore, paneID: String, preparingVoice: Bool = false,
                        applicationActive: @escaping () -> Bool = { NSApp.isActive }) -> DeferredTerminalInputTarget? {
        guard store.focusedID == paneID, let renderer = store.terminalViews[paneID], renderer.store === store,
              let window = renderer.window, let pane = store.sessions.first(where: { $0.id == paneID && $0.alive }),
              let owner = renderer.interactionOwner(), let lease = renderer.interactionLease(for: owner) else { return nil }
        let host = pane.remote.flatMap { remote in store.state.remoteHosts.first { $0.id == remote.hostID } }
        guard pane.remote == nil || host != nil else { return nil }
        let launch = store.state.agentLaunches.first { $0.paneID == paneID && $0.lifecycle == .active }
        let identity = DeferredTerminalInputIdentity(owner: owner, storeID: ObjectIdentifier(store), rendererID: ObjectIdentifier(renderer),
            clientPID: renderer.process.shellPid, backendPID: pane.pid, hostID: pane.remote?.hostID, remoteSessionID: pane.remote?.sessionID,
            providerGeneration: launch?.id, providerPID: launch?.providerPID)
        let attempt = DeferredTerminalInputAttempt(identity: identity, lease: lease)
        let target = DeferredTerminalInputTarget(store: store, renderer: renderer, window: window, attempt: attempt,
            upload: DeferredTerminalUploadTarget(paneID: pane.id, backendPID: pane.pid, remote: pane.remote, host: host, lease: lease,
                providerGeneration: launch?.id, providerPID: launch?.providerPID), applicationActive: applicationActive)
        if preparingVoice { return attempt.matches(target.state(allowVoice: true)) ? target : nil }
        return attempt.readiness(target.state()) == .ready ? target : nil
    }
    func state(allowVoice: Bool = false, intentCurrent: Bool = true) -> DeferredTerminalInputState? {
        guard let store, let renderer, let window, renderer.window === window, renderer.store === store,
              store.terminalViews[attempt.identity.owner.paneID] === renderer,
              let pane = store.sessions.first(where: { $0.id == attempt.identity.owner.paneID && $0.alive }),
              let owner = renderer.interactionOwner(), renderer.interactionLease(for: owner) === attempt.lease else { return nil }
        if let host = upload.host, store.state.remoteHosts.first(where: { $0.id == host.id }) != host { return nil }
        let launch = store.state.agentLaunches.first { $0.paneID == pane.id && $0.lifecycle == .active }
        let identity = DeferredTerminalInputIdentity(owner: owner, storeID: ObjectIdentifier(store), rendererID: ObjectIdentifier(renderer),
            clientPID: renderer.process.shellPid, backendPID: pane.pid, hostID: pane.remote?.hostID, remoteSessionID: pane.remote?.sessionID,
            providerGeneration: launch?.id, providerPID: launch?.providerPID)
        var result = DeferredTerminalInputState(identity: identity, focusedPaneID: store.focusedID ?? "")
        result.visible = window.isVisible && !window.isMiniaturized && !renderer.isHiddenOrHasHiddenAncestor
        result.appActive = applicationActive()
        result.keyWindowID = window.isKeyWindow ? ObjectIdentifier(window) : NSApp.keyWindow.map(ObjectIdentifier.init)
        result.terminalIsFirstResponder = window.firstResponder === renderer
        result.attachedSheetID = window.attachedSheet.map(ObjectIdentifier.init)
        result.modalWindowID = NSApp.modalWindow.map(ObjectIdentifier.init)
        result.markedText = renderer.hasMarkedText() || (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
        result.inputProtected = store.loading || renderer.inputBlocked || store.picker != nil || store.showSettings ||
            store.showRemoteHosts || store.showAccounts || store.showExtensions || store.remotePathRequest != nil ||
            store.showVoice && !allowVoice
        result.intentCurrent = intentCurrent
        return result
    }
    func permitsVoicePreparation(in sheet: NSWindow?) -> Bool {
        guard let sheet, let window,
              (sheet.sheetParent === window && window.attachedSheet === sheet) ||
                (sheet.parent === window && window.childWindows?.contains(where: { $0 === sheet }) == true && window.attachedSheet == nil),
              sheet.isKeyWindow, let state = state(allowVoice: true), attempt.matches(state),
              state.modalWindowID == nil || state.modalWindowID == ObjectIdentifier(sheet) else { return false }
        return (sheet.firstResponder as? NSTextView)?.hasMarkedText() != true
    }
    func ownership(intentCurrent: @escaping () -> Bool = { true }) -> DeferredTerminalInputOwnership {
        DeferredTerminalInputOwnership(attempt: attempt) { [self] in state(intentCurrent: intentCurrent()) }
    }
    @discardableResult func insert(_ text: String, intentCurrent: @escaping () -> Bool = { true },
                                   didInsert: @escaping () -> Void = {}) -> Bool {
        let originalOwner = ownership(intentCurrent: intentCurrent)
        return attempt.commit(current: { state(intentCurrent: intentCurrent()) }) { [weak renderer] in
            renderer?.pasteDraft(text, ownership: originalOwner, didInsert: didInsert)
        }
    }
    func completeVoice(_ text: String, presentationID: UUID, closingSheet: NSWindow?) {
        guard let store, store.voiceInputRecovery.remember(text, presentationID: presentationID,
                                                          currentID: store.voiceInputPresentationID) else { return }
        let sheetID = closingSheet.map(ObjectIdentifier.init)
        let intentCurrent = { [weak store] in store?.voiceInputPresentationID == presentationID && store?.showVoice == false }
        func finish(_ remaining: Int) {
            switch attempt.readiness(state(intentCurrent: intentCurrent()), closingSheetID: sheetID) {
            case .ready:
                _ = insert(text, intentCurrent: intentCurrent) { [weak store] in
                    guard let store, !store.showVoice else { return }
                    store.voiceInputRecovery.clearInserted(presentationID: presentationID, currentID: store.voiceInputPresentationID)
                }
            case .closingPresentation:
                guard remaining > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { finish(remaining - 1) }
            case .cancelled: return
            }
        }
        DispatchQueue.main.async { finish(120) }
    }
}
