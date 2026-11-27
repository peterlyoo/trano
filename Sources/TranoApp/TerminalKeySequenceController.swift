import AppKit
import TerminalCore

@MainActor final class TerminalKeySequenceController {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void
    private(set) var hints: [TerminalKeySequenceHint] = []
    private weak var owner: NSWindow?
    private var map: TerminalKeySequenceMap
    private var tracker = TerminalKeySequenceTracker()
    private weak var pendingResponder: NSResponder?
    private var pendingTarget: String?
    private let schedule: Schedule
    private let now: () -> TimeInterval
    private let eligible: () -> Bool
    private let composing: () -> Bool
    private let target: (() -> String?)?
    private let supportsAction: (ActionID) -> Bool
    private let onHints: ([TerminalKeySequenceHint]) -> Void
    private let dispatch: (ActionID) -> Void
    private var cancelTimeout: (() -> Void)?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    init(owner: NSWindow, overrides: [String: [String]] = [:], schedule: Schedule? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         eligible: @escaping () -> Bool, composing: @escaping () -> Bool,
         target: (() -> String?)? = nil, supportsAction: @escaping (ActionID) -> Bool = { _ in true },
         onHints: @escaping ([TerminalKeySequenceHint]) -> Void,
         dispatch: @escaping (ActionID) -> Void) throws {
        self.owner = owner
        map = try TerminalKeySequenceMap(overrides: overrides)
        self.schedule = schedule ?? { delay, action in
            let work = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return { work.cancel() }
        }
        self.now = now; self.eligible = eligible; self.composing = composing
        self.target = target
        self.supportsAction = supportsAction
        self.onHints = onHints; self.dispatch = dispatch
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
        observers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEligibility() }
        })
    }

    deinit {
        cancelTimeout?()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func reload(overrides: [String: [String]]) throws {
        cancel()
        map = try TerminalKeySequenceMap(overrides: overrides)
    }

    func refreshEligibility() {
        if owner == nil || !eligible() || composing()
            || (!tracker.prefix.isEmpty && (owner?.firstResponder !== pendingResponder || target?() != pendingTarget || !map.hints(after: tracker.prefix).contains(where: { supportsAction($0.action) }))) { cancel() }
    }

    func handle(_ event: NSEvent, showHints: Bool) -> Bool {
        guard let owner, event.window === owner else { cancel(); return false }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { cancel(); return false }
        guard event.type == .keyDown else { refreshEligibility(); return false }
        guard eligible(), !composing() else { cancel(); return false }
        let pending = !tracker.prefix.isEmpty
        if pending, !pendingContextMatches(owner) { cancel(); return false }
        if !showHints { setHints([]) }
        if pending, tracker.prefix.isEmpty || !pendingContextMatches(owner) { cancel(); return false }
        if event.isARepeat { return !tracker.prefix.isEmpty }
        let stroke: String
        if event.keyCode == 53 { stroke = "escape" }
        else if let binding = NativeKeyBinding.binding(for: event) { stroke = binding }
        else { cancel(); return false }
        switch tracker.consume(stroke, map: map, showHints: showHints, now: now()) {
        case .unhandled:
            cancel(); return false
        case .cancelled:
            cancel(); return pending
        case .action(let action):
            let responder = pendingResponder
            let expectedTarget = pendingTarget
            cancel()
            guard self.owner === owner, eligible(), !composing(),
                  owner.firstResponder === responder, target?() == expectedTarget else { return false }
            guard supportsAction(action) else { return true }
            dispatch(action)
            return true
        case .pending(let hints):
            guard map.hints(after: tracker.prefix).contains(where: { supportsAction($0.action) }) else { cancel(); return pending }
            if !pending {
                pendingResponder = owner.firstResponder
                pendingTarget = target?()
            }
            invalidateTimeout()
            let current = generation
            setHints(hints.filter { supportsAction($0.action) })
            guard generation == current, !tracker.prefix.isEmpty, pendingContextMatches(owner),
                  map.hints(after: tracker.prefix).contains(where: { supportsAction($0.action) }) else { cancel(); return false }
            cancelTimeout = schedule(1.5) { [weak self] in
                guard let self, self.generation == current else { return }
                self.cancel()
            }
            return true
        }
    }

    func cancel() {
        tracker.cancel()
        pendingResponder = nil
        pendingTarget = nil
        invalidateTimeout()
        setHints([])
    }

    private func pendingContextMatches(_ owner: NSWindow) -> Bool {
        owner.firstResponder === pendingResponder && target?() == pendingTarget
    }

    private func invalidateTimeout() {
        generation &+= 1
        cancelTimeout?()
        cancelTimeout = nil
    }

    private func setHints(_ value: [TerminalKeySequenceHint]) {
        guard hints != value else { return }
        hints = value
        onHints(value)
    }
}
