import Foundation
import TerminalCore

final class TerminalInterruptInputAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var launchIDs: Set<String>?
    private var coalescingKey: UUID?
    func begin(_ ids: Set<String>) { lock.lock(); launchIDs = ids; coalescingKey = UUID(); lock.unlock() }
    func end() { lock.lock(); launchIDs = nil; coalescingKey = nil; lock.unlock() }

    func guardWriter(runtime: TerminalRuntime, paneID: String, backendPID: Int32,
                     write: @escaping TerminalInputRelay.Writer) -> (writer: TerminalInputRelay.Writer, coalescingKey: UUID?) {
        lock.lock(); let expected = launchIDs, key = coalescingKey; lock.unlock()
        guard let expected else { return (write, nil) }
        let guarded: TerminalInputRelay.Writer = { bytes, completion in
            do {
                try runtime.transaction {
                    let state = try runtime.state()
                    guard state.sessions.contains(where: { $0.id == paneID && $0.pid == backendPID && $0.alive }),
                          Set(state.agentLaunches.filter { $0.paneID == paneID }.map(\.id)).isSubset(of: expected) else {
                        throw TerminalError.invalid("The agent changed before buffered typing reached the shell")
                    }
                    write(bytes, completion)
                }
            } catch { completion(.failure(error)) }
        }
        return (guarded, key)
    }
}
