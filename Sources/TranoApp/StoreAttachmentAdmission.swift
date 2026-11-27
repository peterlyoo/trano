import Foundation
import TerminalCore

extension AppStore {
    @discardableResult func enqueueImage(_ data: Data, target: DeferredTerminalInputTarget,
        save: @escaping @Sendable (Data, DeferredTerminalUploadTarget, TerminalRuntime) throws -> String = { try $1.save($0, runtime: $2) }) -> Bool {
        guard target.attempt.identity.storeID == ObjectIdentifier(self),
              target.attempt.readiness(target.state()) == .ready else { return false }
        let reservation: AttachmentAdmissionBudget.Reservation
        do { reservation = try attachmentAdmission.reserve(byteCount: data.count) }
        catch {
            if target.attempt.readiness(target.state()) == .ready { message = error.localizedDescription }
            return false
        }
        let runtime = runtime, upload = target.upload
        attachmentQueue.async { [weak self] in
            defer { reservation.release() }
            do {
                let path = try save(data, upload, runtime)
                DispatchQueue.main.async { _ = target.insert(ShellQuote.quote(path) + " ") }
            } catch DeferredTerminalInputError.cancelled {
            } catch {
                DispatchQueue.main.async {
                    guard target.attempt.readiness(target.state()) == .ready else { return }
                    self?.message = error.localizedDescription
                }
            }
        }
        return true
    }
}
