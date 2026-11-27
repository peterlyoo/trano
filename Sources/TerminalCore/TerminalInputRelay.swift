import Foundation

public struct TerminalUserInputSegment: Equatable, Sendable {
    public let bytes: [UInt8]
    public let submissionCandidate: Bool
    public let mutatesInput: Bool
    public init(bytes: [UInt8], submissionCandidate: Bool, mutatesInput: Bool = true) {
        self.bytes = bytes; self.submissionCandidate = submissionCandidate; self.mutatesInput = mutatesInput
    }
}

public struct TerminalUserInputScanner {
    private enum Mode { case ground, escape, csi, discardCSI, osc, string, oscEscape, stringEscape }
    private var mode = Mode.ground
    private var parameters: [UInt8] = []
    private var pasting = false
    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [TerminalUserInputSegment] {
        var result: [TerminalUserInputSegment] = []
        var start = 0
        var localSequenceStart: Int?
        for (index, byte) in bytes.enumerated() {
            var submitted = false
            var released = false
            switch mode {
            case .ground:
                if byte == 27 { mode = .escape; localSequenceStart = index }
                else if !pasting, byte == 13 || byte == 10 { submitted = true }
            case .escape:
                switch byte {
                case 91: mode = .csi; parameters.removeAll(keepingCapacity: true)
                case 93: mode = .osc
                case 80, 88, 94, 95: mode = .string
                case 27: localSequenceStart = index
                default: mode = .ground
                }
            case .csi:
                if (0x40...0x7e).contains(byte) {
                    if byte == 126, parameters == [50, 48, 48] { pasting = true }
                    else if byte == 126, parameters == [50, 48, 49] { pasting = false }
                    else if byte == 117, !pasting {
                        let fields = String(decoding: parameters, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
                        let modifiers = fields.count > 1 ? fields[1].split(separator: ":", omittingEmptySubsequences: false) : []
                        let event = modifiers.count > 1 ? Int(modifiers[1]) : 1
                        released = event == 3 && fields.count <= 2 && Int(fields[0]) != nil
                        let modifier = modifiers.isEmpty ? 1 : Int(modifiers[0])
                        submitted = fields.first == "13" && fields.count <= 3 &&
                            modifier.map { $0 > 0 && ($0 - 1) & ~(64 | 128) == 0 } == true && (event == 1 || event == 2)
                    }
                    mode = .ground; parameters.removeAll(keepingCapacity: true)
                } else if (0x20...0x3f).contains(byte), parameters.count < 128 { parameters.append(byte) }
                else if byte == 27 { mode = .escape; localSequenceStart = index }
                else { mode = .discardCSI }
            case .discardCSI:
                if (0x40...0x7e).contains(byte) { mode = .ground }
            case .osc:
                if byte == 7 { mode = .ground }
                else if byte == 27 { mode = .oscEscape }
            case .string:
                if byte == 27 { mode = .stringEscape }
            case .oscEscape:
                if byte == 92 || byte == 7 { mode = .ground }
                else if byte != 27 { mode = .osc }
            case .stringEscape:
                if byte == 92 { mode = .ground }
                else if byte != 27 { mode = .string }
            }
            if submitted {
                result.append(TerminalUserInputSegment(bytes: Array(bytes[start...index]), submissionCandidate: true))
                start = index + 1
            } else if released, let sequence = localSequenceStart, sequence >= start {
                if sequence > start { result.append(TerminalUserInputSegment(bytes: Array(bytes[start..<sequence]), submissionCandidate: false)) }
                result.append(TerminalUserInputSegment(bytes: Array(bytes[sequence...index]), submissionCandidate: false, mutatesInput: false))
                start = index + 1
            }
            if mode == .ground { localSequenceStart = nil }
        }
        if start < bytes.count { result.append(TerminalUserInputSegment(bytes: Array(bytes[start...]), submissionCandidate: false)) }
        return result
    }
}

public final class TerminalInputRelay: @unchecked Sendable {
    public typealias Completion = @Sendable (Result<Int, Error>) -> Void
    public typealias Writer = @Sendable ([UInt8], @escaping Completion) -> Void
    public typealias Delivery = @Sendable ([UInt8], [TerminalUserInputSegment], @escaping Writer, @escaping Completion) -> Void
    private struct Entry {
        var bytes: ArraySlice<UInt8>
        let user: Bool
        let coalescingKey: UUID?
        let writer: Writer
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "trano.terminal-input", qos: .userInteractive)
    private let limitBytes: Int
    private let batchBytes: Int
    private let delayMilliseconds: Int
    private let delivery: Delivery
    private let invalidated: @Sendable (String) -> Void
    private var entries: [Entry] = []
    private var pendingBytes = 0
    private var scheduled = false
    private var cancelled = false
    private var activeID: UUID?
    private var scanner = TerminalUserInputScanner()

    public init(limitBytes: Int = 1_114_112, batchBytes: Int = 8192, delayMilliseconds: Int = 0,
                deliver: @escaping Delivery, invalidated: @escaping @Sendable (String) -> Void) {
        self.limitBytes = max(1, limitBytes); self.batchBytes = max(1, min(batchBytes, limitBytes))
        self.delayMilliseconds = max(0, delayMilliseconds)
        self.delivery = deliver; self.invalidated = invalidated
    }

    @discardableResult public func send(_ bytes: [UInt8], user: Bool, coalescingKey: UUID? = nil, write: @escaping Writer) -> Bool {
        guard !bytes.isEmpty else { return true }
        lock.lock()
        guard !cancelled else { lock.unlock(); return false }
        guard bytes.count <= limitBytes - pendingBytes, entries.count < 256 else {
            lock.unlock()
            queue.async { self.invalidated("Terminal input buffer is full. Review the terminal before resuming queued input.") }
            return false
        }
        entries.append(Entry(bytes: bytes[...], user: user, coalescingKey: coalescingKey, writer: write)); pendingBytes += bytes.count
        let schedule = !scheduled && activeID == nil
        if schedule { scheduled = true }
        lock.unlock()
        if schedule { scheduleDrain() }
        return true
    }

    public func cancel() { cancel(reason: "Terminal input destination changed. Review queued input before resuming.") }

    private func cancel(reason: String, forceNotify: Bool = false) {
        lock.lock()
        let notify = !cancelled && (pendingBytes > 0 || forceNotify)
        cancelled = true; entries.removeAll(); scheduled = false
        lock.unlock()
        if notify { queue.async { self.invalidated(reason) } }
    }

    private func scheduleDrain() {
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) { self.drain() }
    }

    private func drain() {
        lock.lock()
        scheduled = false
        guard !cancelled, activeID == nil, let first = entries.first else { lock.unlock(); return }
        var bytes: [UInt8] = []
        while !entries.isEmpty, entries[0].user == first.user, entries[0].coalescingKey == first.coalescingKey, bytes.count < batchBytes {
            let amount = min(batchBytes - bytes.count, entries[0].bytes.count)
            bytes.append(contentsOf: entries[0].bytes.prefix(amount))
            entries[0].bytes = entries[0].bytes.dropFirst(amount)
            if entries[0].bytes.isEmpty { entries.removeFirst() }
        }
        let id = UUID(); activeID = id
        lock.unlock()
        let segments = first.user ? scanner.feed(bytes) : []
        let count = bytes.count
        delivery(bytes, segments, first.writer) { result in
            self.queue.async { self.finished(id: id, count: count, result: result) }
        }
    }

    private func finished(id: UUID, count: Int, result: Result<Int, Error>) {
        lock.lock()
        guard activeID == id else { lock.unlock(); return }
        activeID = nil; pendingBytes -= count
        let failed: Bool
        switch result { case .success(let written): failed = written != count; case .failure: failed = true }
        let schedule = !cancelled && !failed && !entries.isEmpty
        if schedule { scheduled = true }
        lock.unlock()
        if failed { cancel(reason: "Terminal input could not be confirmed. Review the terminal before resuming queued input.", forceNotify: true) }
        else if schedule { scheduleDrain() }
    }
}
