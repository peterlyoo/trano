import Foundation

public protocol SupervisorWakeSource: AnyObject {
    func wait(timeout: TimeInterval) throws -> Bool
    var inputOnlyWake: Bool { get }
}

extension SupervisorWakeSource { public var inputOnlyWake: Bool { false } }

public enum SupervisorWakeReason: String, Codable { case changed, heartbeat }

public struct SupervisorWatchResult: Codable, Equatable {
    public let reason: SupervisorWakeReason
    public let state: SupervisorState
}

public final class SupervisorWatcher {
    private let source: SupervisorWakeSource
    private let observe: () throws -> SupervisorState
    private let now: () -> TimeInterval
    private let observeReadiness: ((SupervisorState) throws -> SupervisorState)?

    public init(source: SupervisorWakeSource, observe: @escaping () throws -> SupervisorState,
                observeReadiness: ((SupervisorState) throws -> SupervisorState)? = nil,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.source = source
        self.observe = observe
        self.now = now
        self.observeReadiness = observeReadiness
    }

    public func wait(after cursor: SupervisorWatchCursor, timeout: TimeInterval) throws -> SupervisorWatchResult {
        guard timeout.isFinite, timeout > 0, timeout <= 3600 else {
            throw TerminalError.invalid("Supervisor watch timeout must be between 0 and 3600 seconds")
        }
        let deadline = now() + timeout
        var state = try observe()
        while state.cursor == cursor {
            let remaining = deadline - now()
            if remaining <= 0 { return SupervisorWatchResult(reason: .heartbeat, state: state) }
            let signalled = try source.wait(timeout: remaining)
            if signalled, source.inputOnlyWake, let observeReadiness { state = try observeReadiness(state) }
            else { state = try observe() }
            if !signalled || now() >= deadline { break }
        }
        return SupervisorWatchResult(reason: state.cursor == cursor ? .heartbeat : .changed, state: state)
    }
}
