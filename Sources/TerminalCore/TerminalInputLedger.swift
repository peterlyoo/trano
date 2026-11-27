import Foundation
import CryptoKit
import Darwin

public struct TerminalInputBinding: Codable, Equatable, Sendable {
    public let paneID: String
    public let backendPID: Int32
    public let generation: String
    public let providerPID: Int32?

    public init(paneID: String, backendPID: Int32, generation: String, providerPID: Int32? = nil) {
        self.paneID = paneID; self.backendPID = backendPID; self.generation = generation; self.providerPID = providerPID
    }

    fileprivate var isValid: Bool {
        backendPID > 1 && (providerPID.map { $0 > 1 } ?? true) && [paneID, generation].allSatisfy { value in
            !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        }
    }
}

public struct TerminalInputLease: Codable, Equatable, Sendable {
    public let binding: TerminalInputBinding
    public let revision: UInt64
    fileprivate let proofID: String
}

public struct TerminalInputWriteReceipt: Codable, Equatable, Sendable {
    public let binding: TerminalInputBinding
    public let revision: UInt64
    public let capturedAt: Date
    fileprivate let id: String
    fileprivate let isProtocol: Bool
}

public enum TerminalInputReadiness: Equatable, Sendable {
    case ready(TerminalInputLease), inputInFlight, inputReviewRequired, changed

    public var lease: TerminalInputLease? {
        if case .ready(let lease) = self { return lease }
        return nil
    }
}

public struct TerminalInputLedger: Codable, Equatable, Sendable {
    private struct Record: Codable, Equatable, Sendable {
        let binding: TerminalInputBinding
        var revision: UInt64 = 0
        var cleanRevision: UInt64?
        var proofID: String?
        var pendingWrites: [TerminalInputWriteReceipt] = []
        var submissions: [TerminalInputWriteReceipt] = []
        var correlationLost = false
        var uncertaintyNonce: String?
    }

    private var schemaVersion = 1
    private var records: [String: Record] = [:]
    private static let maximumRecords = 4096
    private static let maximumPendingWrites = 128
    private static let maximumSubmissions = 64

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        records = try container.decode([String: Record].self, forKey: .records)
        try validateContents()
    }

    public func ownedInvocationFingerprint(paneID: String) throws -> String {
        guard !paneID.isEmpty, paneID.utf8.count <= 512,
              !paneID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw TerminalError.invalid("Invalid owned invocation pane")
        }
        struct Snapshot: Encodable {
            let version: Int
            let paneID: String
            let record: Record?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(version: 1, paneID: paneID, record: records[paneID]))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public mutating func registerOwnedInvocationPrompt(binding: TerminalInputBinding, expectedPriorFingerprint: String, capturedAt: Date = Date()) throws {
        try requireValid(binding)
        guard let providerPID = binding.providerPID, providerPID > 1, providerPID != binding.backendPID,
              binding.generation != "terminal:\(binding.backendPID)", capturedAt.timeIntervalSinceReferenceDate.isFinite,
              expectedPriorFingerprint == (try ownedInvocationFingerprint(paneID: binding.paneID)),
              records[binding.paneID]?.pendingWrites.isEmpty ?? true,
              records[binding.paneID]?.binding != binding else {
            throw TerminalError.invalid("Owned invocation input changed, is still pending, or was already registered")
        }
        var candidate = self
        let receipt = try candidate.beginManualWrite(binding: binding, submissionCandidate: true, capturedAt: capturedAt)
        guard candidate.finishWrite(receipt, succeeded: true) else { throw TerminalError.invalid("Cannot register the owned invocation prompt") }
        self = candidate
    }

    public mutating func beginManualWrite(binding: TerminalInputBinding, submissionCandidate: Bool = false, capturedAt: Date = Date()) throws -> TerminalInputWriteReceipt {
        try requireValid(binding)
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else { throw TerminalError.invalid("Invalid terminal input time") }
        var record: Record
        if let existing = records[binding.paneID], existing.binding == binding { record = existing }
        else {
            guard records[binding.paneID] != nil || records.count < Self.maximumRecords else {
                throw TerminalError.invalid("Too many terminal input bindings")
            }
            record = Record(binding: binding)
        }
        guard record.pendingWrites.count < Self.maximumPendingWrites else {
            throw TerminalError.invalid("Terminal input is still being written; automatic input is paused")
        }
        guard record.revision < UInt64.max - 1 else { throw TerminalError.invalid("Terminal input revision exhausted") }
        record.revision += 1
        record.cleanRevision = nil; record.proofID = nil
        let receipt = TerminalInputWriteReceipt(binding: binding, revision: record.revision, capturedAt: capturedAt, id: UUID().uuidString.lowercased(), isProtocol: false)
        record.pendingWrites.append(receipt)
        if submissionCandidate, !record.correlationLost {
            if record.submissions.count < Self.maximumSubmissions { record.submissions.append(receipt) }
            else { invalidate(&record, losingCorrelation: true) }
        }
        records[binding.paneID] = record
        return receipt
    }

    public mutating func beginProtocolWrite(binding: TerminalInputBinding) throws -> TerminalInputWriteReceipt {
        try requireValid(binding)
        guard records[binding.paneID] != nil || records.count < Self.maximumRecords else {
            throw TerminalError.invalid("Too many terminal input bindings")
        }
        var record = records[binding.paneID].flatMap { $0.binding == binding ? $0 : nil } ?? Record(binding: binding)
        guard record.pendingWrites.count < Self.maximumPendingWrites else {
            throw TerminalError.invalid("Terminal input is still being written; automatic input is paused")
        }
        let receipt = TerminalInputWriteReceipt(binding: binding, revision: record.revision, capturedAt: Date(),
                                               id: UUID().uuidString.lowercased(), isProtocol: true)
        record.pendingWrites.append(receipt)
        records[binding.paneID] = record
        return receipt
    }

    @discardableResult
    public mutating func finishWrite(_ receipt: TerminalInputWriteReceipt, succeeded: Bool) -> Bool {
        guard var record = records[receipt.binding.paneID], record.binding == receipt.binding,
              let index = record.pendingWrites.firstIndex(of: receipt) else { return false }
        record.pendingWrites.remove(at: index)
        if !succeeded { invalidate(&record, losingCorrelation: true) }
        records[receipt.binding.paneID] = record
        return true
    }

    @discardableResult
    public mutating func observeTrustedSubmit(binding: TerminalInputBinding, originStartedAt: Date = Date()) -> Bool {
        guard var record = records[binding.paneID], record.binding == binding else { return false }
        guard !record.correlationLost, !record.submissions.isEmpty else {
            invalidate(&record, losingCorrelation: record.correlationLost)
            records[binding.paneID] = record
            return false
        }
        guard originStartedAt.timeIntervalSinceReferenceDate.isFinite,
              record.submissions[0].capturedAt <= originStartedAt else {
            record.cleanRevision = nil; record.proofID = nil
            records[binding.paneID] = record
            return false
        }
        let submission = record.submissions.removeFirst()
        record.cleanRevision = submission.revision
        record.proofID = UUID().uuidString.lowercased()
        records[binding.paneID] = record
        return true
    }

    public func readiness(binding: TerminalInputBinding) -> TerminalInputReadiness {
        guard binding.isValid else { return .changed }
        guard let record = records[binding.paneID] else { return .inputReviewRequired }
        guard record.binding == binding else { return .changed }
        guard record.pendingWrites.isEmpty else { return .inputInFlight }
        guard !record.correlationLost, record.submissions.isEmpty, record.cleanRevision == record.revision,
              record.revision < UInt64.max - 1, let proofID = record.proofID else { return .inputReviewRequired }
        return .ready(TerminalInputLease(binding: binding, revision: record.revision, proofID: proofID))
    }

    // True when another plain keystroke cannot change readiness: only a later submission or review can.
    public func manualInputAlreadyUnconfirmed(binding: TerminalInputBinding) -> Bool {
        guard let record = records[binding.paneID], record.binding == binding, record.pendingWrites.isEmpty else { return false }
        return record.revision > max(record.submissions.last?.revision ?? 0, record.cleanRevision ?? 0)
    }

    public func validate(_ lease: TerminalInputLease) -> Bool {
        readiness(binding: lease.binding).lease == lease
    }

    public mutating func beginAutomaticWrite(_ lease: TerminalInputLease) throws -> TerminalInputWriteReceipt {
        guard validate(lease) else { throw TerminalError.invalid("Terminal input changed; review the pane before resuming automatic input") }
        return try beginManualWrite(binding: lease.binding, submissionCandidate: true)
    }

    public mutating func markUncertain(binding: TerminalInputBinding) throws {
        try requireValid(binding)
        guard records[binding.paneID] != nil || records.count < Self.maximumRecords else {
            throw TerminalError.invalid("Too many terminal input bindings")
        }
        var record = records[binding.paneID].flatMap { $0.binding == binding ? $0 : nil } ?? Record(binding: binding)
        invalidate(&record, losingCorrelation: true)
        record.uncertaintyNonce = UUID().uuidString.lowercased()
        records[binding.paneID] = record
    }

    public mutating func review(binding: TerminalInputBinding) throws {
        try requireValid(binding)
        if let record = records[binding.paneID], record.binding == binding, !record.pendingWrites.isEmpty {
            throw TerminalError.invalid("Terminal input is still pending. Wait for it to finish; if its app was interrupted, restart the managed agent before resuming the queue")
        }
        guard records[binding.paneID] != nil || records.count < Self.maximumRecords else {
            throw TerminalError.invalid("Too many terminal input bindings")
        }
        var record = records[binding.paneID].flatMap { $0.binding == binding ? $0 : nil } ?? Record(binding: binding)
        invalidate(&record, losingCorrelation: false)
        records[binding.paneID] = record
    }

    private func requireValid(_ binding: TerminalInputBinding) throws {
        guard binding.isValid else { throw TerminalError.invalid("Invalid terminal input binding") }
    }

    private func invalidate(_ record: inout Record, losingCorrelation: Bool) {
        record.cleanRevision = nil; record.proofID = nil; record.submissions.removeAll()
        record.correlationLost = losingCorrelation
    }

    private func validateContents() throws {
        guard schemaVersion == 1, records.count <= Self.maximumRecords else { throw TerminalError.invalid("Invalid terminal input state") }
        for (paneID, record) in records {
            guard record.binding.isValid, record.binding.paneID == paneID, record.revision < UInt64.max - 1,
                  record.pendingWrites.count <= Self.maximumPendingWrites, record.submissions.count <= Self.maximumSubmissions,
                  Set(record.pendingWrites.map(\.id)).count == record.pendingWrites.count,
                  Set(record.submissions.map(\.id)).count == record.submissions.count,
                  (record.cleanRevision == nil) == (record.proofID == nil),
                  record.cleanRevision.map({ $0 <= record.revision }) ?? true,
                  record.proofID.map({ UUID(uuidString: $0) != nil }) ?? true,
                  record.uncertaintyNonce.map({ UUID(uuidString: $0) != nil }) ?? true,
                  !record.correlationLost || (record.cleanRevision == nil && record.submissions.isEmpty),
                  (record.pendingWrites + record.submissions).allSatisfy({ receipt in
                      receipt.binding == record.binding && (receipt.revision > 0 || receipt.isProtocol) && receipt.revision <= record.revision && UUID(uuidString: receipt.id) != nil && receipt.capturedAt.timeIntervalSinceReferenceDate.isFinite
                  }),
                  record.submissions.allSatisfy({ !$0.isProtocol }),
                  zip(record.submissions, record.submissions.dropFirst()).allSatisfy({ $0.revision < $1.revision }) else {
                throw TerminalError.invalid("Invalid terminal input state")
            }
        }
    }
}

// The caller keeps the runtime transaction through reservation and byte dispatch.
public struct TerminalInputLedgerStore {
    public let root: URL
    private static let maximumBytes = 8 * 1_048_576
    private var directory: URL { root.appendingPathComponent("input-state", isDirectory: true) }

    public init(root: URL) { self.root = root }

    public func load() throws -> TerminalInputLedger {
        guard let data = try read() else { return TerminalInputLedger() }
        return try JSONDecoder().decode(TerminalInputLedger.self, from: data)
    }

    public func save(_ ledger: TerminalInputLedger) throws {
        guard let directory = try validatedDirectory(create: true) else { throw TerminalError.runtime("Cannot create terminal input directory") }
        let previous = try read()
        if let previous { _ = try JSONDecoder().decode(TerminalInputLedger.self, from: previous) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ledger)
        guard data.count <= Self.maximumBytes else { throw TerminalError.invalid("Terminal input state exceeds 8 MiB") }
        if data != previous { try TerminalRuntime.atomicWrite(data, to: directory.appendingPathComponent("terminal-input.json")) }
    }

    private func validatedDirectory(create: Bool) throws -> URL? {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw TerminalError.invalid("Cannot inspect terminal input directory") }
            if !create { return nil }
            guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST,
                  lstat(directory.path, &info) == 0 else { throw TerminalError.runtime("Cannot create terminal input directory") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            throw TerminalError.invalid("Terminal input directory must be private, owned, and not a symbolic link")
        }
        return directory
    }

    private func read() throws -> Data? {
        guard let directory = try validatedDirectory(create: false) else { return nil }
        let fd = open(directory.appendingPathComponent("terminal-input.json").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw TerminalError.invalid("Cannot open private terminal input state") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size >= 0,
              info.st_size <= Self.maximumBytes else { throw TerminalError.invalid("Terminal input state must be a private owned regular file of at most 8 MiB") }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.runtime("Cannot read terminal input state") }
            if count == 0 { break }
            guard data.count + count <= Self.maximumBytes else { throw TerminalError.invalid("Terminal input state exceeds 8 MiB") }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}
