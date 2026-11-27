import Foundation
import CoreFoundation

public struct SessionLoadTarget: Equatable, @unchecked Sendable {
    public let paneID: String
    public let backendPID: Int32
    public let ownershipToken: String
    public let provider: AgentKind
    public let providerSessionID: String?
    public let providerPID: Int32?
    public let hookBindingToken: String
    public let alive: Bool
    public let local: Bool

    public init(paneID: String, backendPID: Int32, ownershipToken: String, provider: AgentKind = .shell,
                providerSessionID: String? = nil, providerPID: Int32? = nil, hookBindingToken: String? = nil,
                alive: Bool = true, local: Bool = true) {
        self.paneID = paneID; self.backendPID = backendPID; self.ownershipToken = ownershipToken
        self.provider = provider; self.providerSessionID = providerSessionID; self.providerPID = providerPID
        self.hookBindingToken = hookBindingToken ?? ownershipToken
        self.alive = alive; self.local = local
    }
}

public struct SessionLoadProcess: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let userID: UInt32
    public let startedAtMicroseconds: UInt64
    public let cpuNanoseconds: UInt64
    public let residentBytes: UInt64

    public init(pid: Int32, parentPID: Int32, userID: UInt32, startedAtMicroseconds: UInt64,
                cpuNanoseconds: UInt64, residentBytes: UInt64) {
        self.pid = pid; self.parentPID = parentPID; self.userID = userID
        self.startedAtMicroseconds = startedAtMicroseconds
        self.cpuNanoseconds = cpuNanoseconds; self.residentBytes = residentBytes
    }
}

public struct SessionLoadBatch: Sendable {
    public let processes: [SessionLoadProcess]
    public let userID: UInt32
    public let observedAt: Date
    public let monotonicSeconds: Double
    public let complete: Bool

    public init(processes: [SessionLoadProcess], userID: UInt32, observedAt: Date,
                monotonicSeconds: Double, complete: Bool = true) {
        self.processes = processes; self.userID = userID; self.observedAt = observedAt
        self.monotonicSeconds = monotonicSeconds; self.complete = complete
    }
}

public enum SessionLoadStatus: String, Codable, Sendable {
    case available, warmingUp = "warming_up", stale, unavailable, stopped, remoteUnavailable = "remote_unavailable"
}

public enum SessionHookStatus: String, Codable, Sendable { case available, unavailable, stale }

public struct SessionHookLatency: Codable, Equatable, Sendable {
    public var p99Milliseconds: Double?
    public var sampleCount: Int
    public var windowSeconds: Int
    public var scope: String
    public var status: SessionHookStatus
    public var observedAt: Date?
    public var latestEventAt: Date?

    public init(p99Milliseconds: Double? = nil, sampleCount: Int = 0, windowSeconds: Int = 1800,
                scope: String = "individual_claude_stop_hook", status: SessionHookStatus = .unavailable,
                observedAt: Date? = nil, latestEventAt: Date? = nil) {
        self.p99Milliseconds = p99Milliseconds; self.sampleCount = sampleCount; self.windowSeconds = windowSeconds
        self.scope = scope; self.status = status; self.observedAt = observedAt; self.latestEventAt = latestEventAt
    }
}

public struct SessionHookTail: Sendable {
    public let paneID: String
    public let ownershipToken: String
    public let providerSessionID: String
    public let collectedAt: Date
    public let fileOffset: UInt64
    public let bytes: Data

    public init(paneID: String, ownershipToken: String, providerSessionID: String,
                collectedAt: Date, fileOffset: UInt64 = 0, bytes: Data) {
        self.paneID = paneID; self.ownershipToken = ownershipToken; self.providerSessionID = providerSessionID
        self.collectedAt = collectedAt; self.fileOffset = fileOffset; self.bytes = bytes
    }
}

public struct SessionLoadPoint: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let cpuPercent: Double?
    public let residentBytes: UInt64?
    public init(observedAt: Date, cpuPercent: Double?, residentBytes: UInt64?) {
        self.observedAt = observedAt; self.cpuPercent = cpuPercent; self.residentBytes = residentBytes
    }
}

public struct SessionLoadSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { paneID }
    public let paneID: String
    public let backendPID: Int32
    public var status: SessionLoadStatus
    public var cpuPercent: Double?
    public var residentBytes: UInt64?
    public var processCount: Int?
    public var observedAt: Date?
    public var hook: SessionHookLatency
    public var history: [SessionLoadPoint]

    public init(paneID: String, backendPID: Int32, status: SessionLoadStatus = .unavailable,
                cpuPercent: Double? = nil, residentBytes: UInt64? = nil, processCount: Int? = nil,
                observedAt: Date? = nil, hook: SessionHookLatency = SessionHookLatency(), history: [SessionLoadPoint] = []) {
        self.paneID = paneID; self.backendPID = backendPID; self.status = status; self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes; self.processCount = processCount; self.observedAt = observedAt
        self.hook = hook; self.history = history
    }

    public func freshened(at now: Date) -> SessionLoadSnapshot {
        var snapshot = self
        if let observed = observedAt, status == .available || status == .warmingUp {
            let age = now.timeIntervalSince(observed)
            if age > 6 || age < 0 {
                snapshot.status = .stale
                snapshot.cpuPercent = nil; snapshot.residentBytes = nil; snapshot.processCount = nil
            }
        }
        if let observed = hook.observedAt, hook.status == .available {
            let age = now.timeIntervalSince(observed)
            let eventAge = hook.latestEventAt.map { now.timeIntervalSince($0) } ?? .infinity
            if age > 65 || age < 0 || eventAge > 1800 || eventAge < 0 {
                snapshot.hook.status = .stale; snapshot.hook.p99Milliseconds = nil
            }
        }
        return snapshot
    }
}

public enum SessionHookLatencyParser {
    public static func summarize(target: SessionLoadTarget, tails: [SessionHookTail], now: Date) -> SessionHookLatency {
        guard target.local, target.alive, target.provider == .claude,
              let providerID = target.providerSessionID, !providerID.isEmpty else { return SessionHookLatency() }
        let matching = tails.filter {
            $0.paneID == target.paneID && $0.ownershipToken == target.ownershipToken &&
            $0.providerSessionID == providerID && $0.collectedAt <= now
        }.prefix(16)
        var samples: [(Double, Date)] = []
        var sampleCursor = 0
        var observedAt: Date?
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for tail in matching {
            observedAt = max(observedAt ?? tail.collectedAt, tail.collectedAt)
            let truncated = tail.bytes.count > 262_144
            let bytes = truncated ? Data(tail.bytes.suffix(262_144)) : tail.bytes
            var lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
            if tail.fileOffset > 0 || truncated { if !lines.isEmpty { lines.removeFirst() } }
            if !lines.isEmpty { lines.removeLast() }
            for line in lines where line.count <= 65_536 {
                guard line.range(of: Data("stop_hook_summary".utf8)) != nil,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["type"] as? String == "system", object["subtype"] as? String == "stop_hook_summary",
                      let stamp = object["timestamp"] as? String,
                      let eventAt = fractional.date(from: stamp) ?? plain.date(from: stamp),
                      eventAt <= now, now.timeIntervalSince(eventAt) <= 1800,
                      let hooks = object["hookInfos"] as? [[String: Any]] else { continue }
                if let session = object["sessionId"], session as? String != providerID { continue }
                if let session = object["session_id"], session as? String != providerID { continue }
                for hook in hooks {
                    guard let number = hook["durationMs"] as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite, number.doubleValue >= 0 else { continue }
                    let sample = (number.doubleValue, eventAt)
                    if samples.count < 4096 { samples.append(sample) }
                    else { samples[sampleCursor] = sample; sampleCursor = (sampleCursor + 1) % 4096 }
                }
            }
        }
        guard !samples.isEmpty else { return SessionHookLatency(observedAt: observedAt) }
        let sorted = samples.map(\.0).sorted()
        let rank = max(0, Int(ceil(Double(sorted.count) * 0.99)) - 1)
        return SessionHookLatency(p99Milliseconds: sorted[rank], sampleCount: sorted.count,
                                  status: .available, observedAt: observedAt, latestEventAt: samples.map(\.1).max())
    }
}

public struct SessionLoadEngine {
    private struct Identity: Hashable {
        let pid: Int32
        let start: UInt64
        init(_ process: SessionLoadProcess) { pid = process.pid; start = process.startedAtMicroseconds }
    }
    private struct Entry {
        var target: SessionLoadTarget
        var identity: Identity?
        var rejected = false
        var counters: [Identity: UInt64] = [:]
        var monotonicSeconds: Double?
        var previousObservedAt: Date?
        var snapshot: SessionLoadSnapshot
    }
    private var entries: [String: Entry] = [:]
    public init() {}
    public mutating func ingest(targets: [SessionLoadTarget], batch: SessionLoadBatch,
                                hookTails: [SessionHookTail] = [], hookRefreshAttempted: Bool = false,
                                hookRefreshAttemptedPaneIDs: Set<String>? = nil,
                                now: Date) -> [SessionLoadSnapshot] {
        let groups = Dictionary(grouping: targets, by: \.paneID)
        let unique = targets.filter { groups[$0.paneID]?.count == 1 }
        let paneIDs = Set(unique.map(\.paneID))
        entries = entries.filter { paneIDs.contains($0.key) }
        let roots = Dictionary(grouping: unique.filter { $0.local && $0.alive }, by: \.backendPID)
        let processGroups = Dictionary(grouping: batch.processes.prefix(16_385), by: \.pid)
        let processes = processGroups.compactMapValues { values -> SessionLoadProcess? in
            guard values.count == 1, let value = values.first, value.pid > 1,
                  value.userID == batch.userID, value.startedAtMicroseconds > 0 else { return nil }
            return value
        }
        var assigned: [String: [SessionLoadProcess]] = [:]
        if batch.complete && batch.processes.count <= 16_384 {
            for process in processes.values {
                if let pane = Self.owner(process, roots: roots, processes: processes) {
                    assigned[pane, default: []].append(process)
                }
            }
        }
        for target in unique {
            var entry = entries[target.paneID] ?? Entry(target: target,
                snapshot: SessionLoadSnapshot(paneID: target.paneID, backendPID: target.backendPID))
            if entry.target != target {
                entry = Entry(target: target, snapshot: SessionLoadSnapshot(paneID: target.paneID, backendPID: target.backendPID))
            }
            if let providerPID = target.providerPID, assigned[target.paneID]?.contains(where: { $0.pid == providerPID }) != true {
                entry.snapshot.hook = SessionHookLatency()
            } else if (hookRefreshAttemptedPaneIDs?.contains(target.paneID) ?? hookRefreshAttempted) || hookTails.contains(where: { $0.paneID == target.paneID && $0.ownershipToken == target.ownershipToken }) {
                entry.snapshot.hook = SessionHookLatencyParser.summarize(target: target, tails: hookTails, now: now)
            }
            if !target.alive {
                Self.unavailable(&entry, status: .stopped)
            } else if !target.local {
                Self.unavailable(&entry, status: .remoteUnavailable)
            } else if !batch.complete || batch.processes.count > 16_384 || roots[target.backendPID]?.count != 1 {
                Self.unavailable(&entry)
            } else if let root = processes[target.backendPID] {
                let identity = Identity(root)
                if let bound = entry.identity, bound != identity { entry.rejected = true }
                if entry.rejected {
                    Self.unavailable(&entry)
                    entry.snapshot.hook = SessionHookLatency()
                    entry.snapshot.history = []
                } else {
                    entry.identity = identity
                    Self.sample(&entry, processes: assigned[target.paneID] ?? [], batch: batch)
                }
            } else { Self.unavailable(&entry) }
            entries[target.paneID] = entry
        }
        return unique.compactMap { cached(paneID: $0.paneID, now: now) }
    }

    public func cached(paneID: String, now: Date) -> SessionLoadSnapshot? {
        entries[paneID]?.snapshot.freshened(at: now)
    }

    private static func owner(_ process: SessionLoadProcess, roots: [Int32: [SessionLoadTarget]],
                              processes: [Int32: SessionLoadProcess]) -> String? {
        var current = process
        var visited: Set<Int32> = []
        for _ in 0..<64 {
            guard visited.insert(current.pid).inserted else { return nil }
            if let candidates = roots[current.pid] { return candidates.count == 1 ? candidates.first?.paneID : nil }
            guard let parent = processes[current.parentPID], parent.startedAtMicroseconds <= current.startedAtMicroseconds else { return nil }
            current = parent
        }
        return nil
    }

    private static func unavailable(_ entry: inout Entry, status: SessionLoadStatus = .unavailable) {
        entry.snapshot.status = status; entry.snapshot.cpuPercent = nil; entry.snapshot.residentBytes = nil
        entry.snapshot.processCount = nil; entry.snapshot.observedAt = nil
        entry.counters = [:]; entry.monotonicSeconds = nil; entry.previousObservedAt = nil
    }

    private static func sample(_ entry: inout Entry, processes: [SessionLoadProcess], batch: SessionLoadBatch) {
        var memory: UInt64? = 0
        for process in processes {
            if let current = memory {
                let addition = current.addingReportingOverflow(process.residentBytes)
                memory = addition.overflow ? nil : addition.partialValue
            }
        }
        var cpu: Double?
        if let previousTick = entry.monotonicSeconds, let previousDate = entry.previousObservedAt {
            let elapsed = batch.monotonicSeconds - previousTick
            if elapsed.isFinite && elapsed > 0 {
                var delta = 0.0
                var valid = true
                for process in processes {
                    if let previous = entry.counters[Identity(process)] {
                        guard process.cpuNanoseconds >= previous else { valid = false; break }
                        delta += Double(process.cpuNanoseconds - previous)
                    } else if Double(process.startedAtMicroseconds) > previousDate.timeIntervalSince1970 * 1_000_000 {
                        delta += Double(process.cpuNanoseconds)
                    } else { valid = false; break }
                }
                let percent = delta / 1_000_000_000 / elapsed * 100
                if valid && percent.isFinite && percent >= 0 { cpu = percent }
            }
        }
        entry.counters = Dictionary(uniqueKeysWithValues: processes.map { (Identity($0), $0.cpuNanoseconds) })
        entry.monotonicSeconds = batch.monotonicSeconds
        entry.previousObservedAt = batch.observedAt
        entry.snapshot.status = cpu == nil ? .warmingUp : .available
        entry.snapshot.cpuPercent = cpu; entry.snapshot.residentBytes = memory
        entry.snapshot.processCount = processes.count; entry.snapshot.observedAt = batch.observedAt
        entry.snapshot.history.append(SessionLoadPoint(observedAt: batch.observedAt, cpuPercent: cpu, residentBytes: memory))
        if entry.snapshot.history.count > 60 { entry.snapshot.history.removeFirst(entry.snapshot.history.count - 60) }
    }
}
