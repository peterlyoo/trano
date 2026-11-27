import AppKit

@MainActor protocol TerminalInteractionInvalidating: AnyObject {
    func invalidateTerminalInteractions()
}

struct TerminalInteractionOwner: Equatable, Sendable {
    let paneID: String
    let windowID: ObjectIdentifier
    let generation: UUID
}

final class TerminalInteractionLease: @unchecked Sendable {
    let owner: TerminalInteractionOwner
    let sessionPID: Int32
    let hostID: String?
    private let lock = NSLock()
    private var valid = true
    init(owner: TerminalInteractionOwner, sessionPID: Int32, hostID: String? = nil) {
        self.owner = owner; self.sessionPID = sessionPID; self.hostID = hostID
    }
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}
