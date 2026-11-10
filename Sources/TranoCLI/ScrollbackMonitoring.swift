import Foundation
import TerminalCore

func monitorPane(_ paneID: String, runtime: TerminalRuntime) throws {
    guard let backendPID = try runtime.state().sessions.first(where: { $0.id == paneID })?.pid else { return }
    var scanner = ActivityScanner()
    var dirty = true
    var lastSnapshot = ProcessInfo.processInfo.systemUptime
    var bytes = [UInt8](repeating: 0, count: 65536)
    while true {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 1000)
        if ready < 0 { if errno == EINTR { continue }; break }
        if ready > 0 {
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { if dirty { try? runtime.snapshotScrollback(paneID, expectedPID: backendPID) }; break }
            if count < 0 { if errno == EINTR { continue }; break }
            dirty = true
            for report in scanner.feed(Data(bytes.prefix(count))) {
                try? runtime.report(paneID, report: report)
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if dirty && now - lastSnapshot >= 5 {
            try? runtime.snapshotScrollback(paneID, expectedPID: backendPID)
            dirty = false; lastSnapshot = now
        }
    }
}
