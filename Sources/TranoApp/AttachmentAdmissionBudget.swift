import Foundation

final class AttachmentAdmissionBudget: @unchecked Sendable {
    static let maximumCount = 2
    static let maximumAttachmentBytes = 20 * 1_048_576
    static let maximumTotalBytes = 40 * 1_048_576
    struct Usage: Equatable { let count: Int; let bytes: Int }
    enum Rejection: LocalizedError {
        case invalidSize, oversized, busy
        var errorDescription: String? {
            switch self {
            case .invalidSize: return "The image size is invalid."
            case .oversized: return "Images are limited to 20 MiB."
            case .busy: return "Two images are already being uploaded. Try pasting again when an upload finishes."
            }
        }
    }
    final class Reservation: @unchecked Sendable {
        private let lock = NSLock()
        private var budget: AttachmentAdmissionBudget?
        private let byteCount: Int
        fileprivate init(budget: AttachmentAdmissionBudget, byteCount: Int) { self.budget = budget; self.byteCount = byteCount }
        func release() {
            lock.lock()
            let owner = budget
            budget = nil
            lock.unlock()
            owner?.release(byteCount: byteCount)
        }
        deinit { release() }
    }
    private let lock = NSLock()
    private var count = 0
    private var bytes = 0
    var usage: Usage { lock.lock(); defer { lock.unlock() }; return Usage(count: count, bytes: bytes) }
    func reserve(byteCount: Int) throws -> Reservation {
        guard byteCount >= 0 else { throw Rejection.invalidSize }
        guard byteCount <= Self.maximumAttachmentBytes else { throw Rejection.oversized }
        lock.lock(); defer { lock.unlock() }
        guard count < Self.maximumCount, byteCount <= Self.maximumTotalBytes - bytes else { throw Rejection.busy }
        count += 1; bytes += byteCount
        return Reservation(budget: self, byteCount: byteCount)
    }
    private func release(byteCount: Int) {
        lock.lock(); defer { lock.unlock() }
        count -= 1; bytes -= byteCount
    }
}
