import AppKit

struct DeferredTerminalInputIdentity: Equatable {
    let owner: TerminalInteractionOwner
    let storeID: ObjectIdentifier
    let rendererID: ObjectIdentifier
    let clientPID: Int32
    let backendPID: Int32
    let hostID: String?
    let remoteSessionID: String?
    let providerGeneration: String?
    let providerPID: Int32?
    init(owner: TerminalInteractionOwner, storeID: ObjectIdentifier, rendererID: ObjectIdentifier, clientPID: Int32,
         backendPID: Int32, hostID: String?, remoteSessionID: String?, providerGeneration: String? = nil, providerPID: Int32? = nil) {
        self.owner = owner; self.storeID = storeID; self.rendererID = rendererID; self.clientPID = clientPID
        self.backendPID = backendPID; self.hostID = hostID; self.remoteSessionID = remoteSessionID
        self.providerGeneration = providerGeneration; self.providerPID = providerPID
    }
}

struct DeferredTerminalInputState {
    var identity: DeferredTerminalInputIdentity
    var focusedPaneID: String
    var visible = true
    var appActive = true
    var keyWindowID: ObjectIdentifier?
    var terminalIsFirstResponder = true
    var attachedSheetID: ObjectIdentifier?
    var modalWindowID: ObjectIdentifier?
    var markedText = false
    var inputProtected = false
    var intentCurrent = true
}

enum DeferredTerminalInputReadiness: Equatable { case ready, closingPresentation, cancelled }

@MainActor final class DeferredTerminalInputAttempt {
    let identity: DeferredTerminalInputIdentity
    let lease: TerminalInteractionLease
    private(set) var consumed = false
    init(identity: DeferredTerminalInputIdentity, lease: TerminalInteractionLease) { self.identity = identity; self.lease = lease }
    func matches(_ state: DeferredTerminalInputState?) -> Bool {
        !consumed && owns(state)
    }
    private func owns(_ state: DeferredTerminalInputState?) -> Bool {
        guard lease.isValid, let state, state.identity == identity,
              lease.owner == identity.owner, lease.sessionPID == identity.backendPID, lease.hostID == identity.hostID,
              state.focusedPaneID == identity.owner.paneID, state.visible, state.appActive,
              !state.markedText, !state.inputProtected, state.intentCurrent else { return false }
        return true
    }
    func readiness(_ state: DeferredTerminalInputState?, closingSheetID: ObjectIdentifier? = nil) -> DeferredTerminalInputReadiness {
        guard matches(state), let state else { return .cancelled }
        if let closingSheetID,
           state.attachedSheetID == closingSheetID || state.keyWindowID == closingSheetID {
            guard state.attachedSheetID == nil || state.attachedSheetID == closingSheetID,
                  state.modalWindowID == nil || state.modalWindowID == closingSheetID,
                  state.keyWindowID == closingSheetID || state.keyWindowID == identity.owner.windowID else { return .cancelled }
            return .closingPresentation
        }
        guard state.keyWindowID == identity.owner.windowID, state.terminalIsFirstResponder,
              state.attachedSheetID == nil, state.modalWindowID == nil else { return .cancelled }
        return .ready
    }
    func ownershipReadiness(_ state: DeferredTerminalInputState?) -> DeferredTerminalInputReadiness {
        guard owns(state), let state, state.keyWindowID == identity.owner.windowID,
              state.terminalIsFirstResponder, state.attachedSheetID == nil, state.modalWindowID == nil else { return .cancelled }
        return .ready
    }
    @discardableResult func commit(current: () -> DeferredTerminalInputState?, insert: () -> Void) -> Bool {
        let state = current()
        guard readiness(state) == .ready else { return false }
        consumed = true
        insert()
        return true
    }
}

@MainActor struct DeferredTerminalInputOwnership {
    private let current: () -> Bool
    init(attempt: DeferredTerminalInputAttempt, state: @escaping () -> DeferredTerminalInputState?) {
        current = { attempt.ownershipReadiness(state()) == .ready }
    }
    func isCurrent() -> Bool { current() }
}
