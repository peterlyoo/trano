import Foundation
import TerminalCore

enum MonitorCLI {
    struct Invocation {
        let paneID: String
        let expectedPID: Int32
    }

    static func parse(_ arguments: [String]) throws -> Invocation {
        guard arguments.count == 2, UUID(uuidString: arguments[0]) != nil,
              let expectedPID = Int32(arguments[1]), expectedPID > 0 else {
            throw TerminalError.invalid("monitor requires ID and a positive process ID")
        }
        return Invocation(paneID: arguments[0], expectedPID: expectedPID)
    }
}

func monitorPane(_ paneID: String, expectedPID: Int32, runtime: TerminalRuntime) throws {
    guard expectedPID > 0, try runtime.state().sessions.first(where: { $0.id == paneID })?.pid == expectedPID else { return }
    let backendPID = expectedPID
    var scanner = ActivityScanner()
    var pasteScanner = FollowUpPasteScanner()
    var notificationScanner = TerminalNotificationScanner()
    var notificationGate = TerminalNotificationGate()
    var notificationPreferences = NotificationPreferences()
    var lastNotificationPreferenceCheck = -TimeInterval.infinity
    let notificationInFlight = DispatchSemaphore(value: 1)
    try? runtime.recordFollowUpPasteMode(paneID: paneID, expectedPID: backendPID, enabled: false)
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
            let output = Data(bytes.prefix(count))
            let notices = notificationScanner.feed(output)
            if let notice = notices.first {
                let clock = ProcessInfo.processInfo.systemUptime
                if clock - lastNotificationPreferenceCheck >= 5 {
                    notificationPreferences = (try? runtime.notificationPreferences()) ?? NotificationPreferences()
                    lastNotificationPreferenceCheck = clock
                }
                if notificationGate.allow(now: clock, enabled: notificationPreferences.terminalNotifications), notificationInFlight.wait(timeout: .now()) == .success {
                    DispatchQueue.global(qos: .utility).async {
                        defer { notificationInFlight.signal() }
                        guard (try? runtime.state().sessions.first(where: { $0.id == paneID })?.pid) == backendPID else { return }
                        _ = try? APIClient(path: runtime.root.appendingPathComponent("api.sock").path).call(APIRequest(method: "notifications.publish", params: [
                            "kind": .string("terminal"), "paneID": .string(paneID), "expectedPID": .number(Double(backendPID)),
                            "title": .string(notice.title), "body": .string(notice.body)
                        ]))
                    }
                }
            }
            for enabled in pasteScanner.feed(output) {
                try? runtime.recordFollowUpPasteMode(paneID: paneID, expectedPID: backendPID, enabled: enabled)
            }
            for report in scanner.feed(output) {
                try? runtime.report(paneID, report: report, expectedPID: backendPID)
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if dirty && now - lastSnapshot >= 5 {
            try? runtime.snapshotScrollback(paneID, expectedPID: backendPID)
            dirty = false; lastSnapshot = now
        }
    }
}
