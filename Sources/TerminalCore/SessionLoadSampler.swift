import Foundation

public struct SessionLoadMoment {
    public let date: Date
    public let monotonicSeconds: Double
    public init(date: Date, monotonicSeconds: Double) { self.date = date; self.monotonicSeconds = monotonicSeconds }
}

public protocol SessionLoadSource: AnyObject {
    func processes(targets: [SessionLoadTarget], at moment: SessionLoadMoment) -> SessionLoadBatch
    func hookTails(targets: [SessionLoadTarget], at moment: SessionLoadMoment) -> [SessionHookTail]?
}

public enum SessionLoadClockUnits {
    public static func nanoseconds(userTicks: UInt64, systemTicks: UInt64,
                                   numerator: UInt32, denominator: UInt32) -> UInt64? {
        guard numerator > 0, denominator > 0 else { return nil }
        let sum = userTicks.addingReportingOverflow(systemTicks)
        guard !sum.overflow else { return nil }
        let product = sum.partialValue.multipliedFullWidth(by: UInt64(numerator))
        guard product.high < UInt64(denominator) else { return nil }
        return UInt64(denominator).dividingFullWidth(product).quotient
    }
}

public final class SessionLoadSampler {
    public typealias Schedule = (@escaping () -> Void) -> Void
    private let source: SessionLoadSource
    private let schedule: Schedule
    private let clock: () -> SessionLoadMoment
    private let lock = NSLock()
    private var engine = SessionLoadEngine()
    private var hookSelection = SessionHookFairSelection()
    private var targets: [SessionLoadTarget] = []
    private var publishedTargets: [String: SessionLoadTarget] = [:]
    private var lastProcessTick: Double?
    private var lastHookTick: Double?
    private var inFlight = false
    private var stopped = false

    public init(source: SessionLoadSource, schedule: Schedule? = nil,
                clock: @escaping () -> SessionLoadMoment = { SessionLoadMoment(date: Date(), monotonicSeconds: ProcessInfo.processInfo.systemUptime) }) {
        self.source = source; self.clock = clock
        if let schedule { self.schedule = schedule }
        else {
            let queue = DispatchQueue(label: "trano.session-load", qos: .utility)
            self.schedule = { action in queue.async(execute: DispatchWorkItem(block: action)) }
        }
    }

    public func requestRefresh(targets: [SessionLoadTarget]) {
        let moment = clock()
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let next = Array(targets.prefix(4096))
        let changed = self.targets != next
        self.targets = next
        for (paneID, bindings) in Dictionary(grouping: next, by: \.paneID) where bindings.count > 1 {
            publishedTargets.removeValue(forKey: paneID)
        }
        guard !inFlight else { lock.unlock(); return }
        if !changed, let last = lastProcessTick, moment.monotonicSeconds >= last,
           moment.monotonicSeconds - last < 2 { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        schedule { [weak self] in self?.collect() }
    }

    public func snapshots() -> [SessionLoadSnapshot] {
        let now = clock().date
        lock.lock()
        defer { lock.unlock() }
        return targets.compactMap { target in
            guard publishedTargets[target.paneID] == target else { return nil }
            return engine.cached(paneID: target.paneID, now: now)
        }
    }

    public func stop() {
        lock.lock()
        stopped = true; targets = []; publishedTargets = [:]; engine = SessionLoadEngine(); hookSelection = SessionHookFairSelection()
        lock.unlock()
    }

    private func collect() {
        let moment = clock()
        lock.lock()
        guard !stopped else { inFlight = false; lock.unlock(); return }
        let captured = targets
        let refreshHooks = lastHookTick.map { moment.monotonicSeconds < $0 || moment.monotonicSeconds - $0 >= 30 } ?? true
        let hookTargets = refreshHooks ? hookSelection.next(targets: captured) : []
        if refreshHooks { lastHookTick = moment.monotonicSeconds }
        lock.unlock()
        let batch = source.processes(targets: captured, at: moment)
        let tails = refreshHooks && !hookTargets.isEmpty ? source.hookTails(targets: hookTargets, at: moment) : nil
        lock.lock()
        guard !stopped else { inFlight = false; lock.unlock(); return }
        let latest = targets
        if latest == captured {
            _ = engine.ingest(targets: captured, batch: batch, hookTails: tails ?? [],
                              hookRefreshAttemptedPaneIDs: tails == nil ? [] : Set(hookTargets.map(\.paneID)), now: moment.date)
            publishedTargets = Dictionary(captured.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
            lastProcessTick = moment.monotonicSeconds
        } else { lastProcessTick = nil }
        inFlight = false
        lock.unlock()
        if latest != captured { requestRefresh(targets: latest) }
    }
}
