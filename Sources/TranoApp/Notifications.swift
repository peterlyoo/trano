import AppKit
import TerminalCore
import UserNotifications

final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    private let runtime: TerminalRuntime
    private let queue = DispatchQueue(label: "trano.notifications")
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var cursor: Int
    private let cursorURL: URL
    private let applicationURL: URL
    private var remoteWorker: RemoteActivityWorker?
    private let identity = BuildIdentity.process
    private let shutdownLock = NSLock()
    private var shutdownRequested = false
    private var shutdownDelivered = false
    var onShutdown: (() -> Void)?

    init(runtime: TerminalRuntime, applicationURL: URL) {
        self.runtime = runtime
        self.applicationURL = applicationURL
        cursorURL = runtime.root.appendingPathComponent("notification-cursor")
        cursor = (try? String(contentsOf: cursorURL, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? (try? runtime.state().revision) ?? 0
        super.init()
    }

    func start() {
        remoteWorker = RemoteActivityWorker(runtime: runtime)
        UNUserNotificationCenter.current().delegate = self
        let fd = open(runtime.root.path, O_EVTONLY | O_CLOEXEC)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: queue)
            source.setEventHandler { [weak self] in self?.schedule() }
            source.setCancelHandler { close(fd) }
            source.resume(); watcher = source
        }
        queue.async { [weak self] in self?.refresh() }
    }

    func handle(_ request: APIRequest) throws -> JSONValue? {
        if request.method == "service.shutdown" {
            guard request.params["expectedBuildID"] == .string(identity.buildID),
                  request.params["expectedPID"] == .number(Double(getpid())), onShutdown != nil else {
                throw TerminalError.invalid("Background service identity changed; shutdown was not accepted.")
            }
            if let replacement = request.params["replacementBuildID"] {
                let installed = try BuildIdentity(metadataURL: applicationURL.appendingPathComponent("Contents/Info.plist"))
                guard replacement == .string(installed.buildID), installed.isBundled, installed != identity else {
                    throw TerminalError.invalid("The requested replacement is not the currently installed Trano build.")
                }
            }
            shutdownLock.lock(); shutdownRequested = true; shutdownLock.unlock()
            return .object(["accepted": .bool(true), "buildID": .string(identity.buildID), "pid": .number(Double(getpid()))])
        }
        if request.method == "notifications.authorize" {
            DispatchQueue.main.async {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            return .object(["requested": .bool(true)])
        }
        if request.method == "notifications.status" {
            let semaphore = DispatchSemaphore(value: 0)
            var value = "unknown"
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                value = Self.authorization(settings.authorizationStatus)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 5) == .success else { throw TerminalError.runtime("Notification status timed out") }
            return .object(["authorization": .string(value), "backgroundWorker": .bool(true)])
        }
        return nil
    }

    func responseDidSend(_ request: APIRequest, _ response: APIResponse) {
        guard request.method == "service.shutdown", response.error == nil,
              response.result?["accepted"] == .bool(true) else { return }
        shutdownLock.lock()
        let deliver = shutdownRequested && !shutdownDelivered
        if deliver { shutdownDelivered = true }
        shutdownLock.unlock()
        if deliver {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending?.cancel(); self.watcher?.cancel(); self.watcher = nil
                self.remoteWorker = nil
                self.onShutdown?()
            }
        }
    }

    private static func authorization(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        default: return "unknown"
        }
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    private func refresh() {
        guard let state = try? runtime.state(), state.revision != cursor,
              let batch = try? runtime.events(since: min(cursor, state.revision)) else { return }
        if state.settings.notifications {
            let latest = Dictionary(batch.events.map { ($0.sessionID, $0) }, uniquingKeysWith: { _, right in right })
            for event in latest.values where [.done, .error, .blocked].contains(event.activity.state) {
                let content = UNMutableNotificationContent()
                content.title = String(event.title.prefix(100))
                content.body = event.activity.state == .done ? "Task completed" : event.activity.state == .blocked ? "Waiting for your attention" : "Task ended with an error"
                content.sound = .default
                content.userInfo = ["sessionID": event.sessionID]
                let request = UNNotificationRequest(identifier: "activity.\(event.sessionID).\(event.revision)", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request) { _ in }
            }
        }
        cursor = batch.revision
        try? TerminalRuntime.atomicWrite(Data("\(cursor)\n".utf8), to: cursorURL)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard let id = response.notification.request.content.userInfo["sessionID"] as? String, UUID(uuidString: id) != nil else { completionHandler(); return }
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            guard let url = URL(string: "trano://session/" + id) else { completionHandler(); return }
            NSWorkspace.shared.open([url], withApplicationAt: self.applicationURL, configuration: configuration) { _, _ in completionHandler() }
        }
    }
}

final class RemoteActivityWorker {
    private let runtime: TerminalRuntime
    private let queue = DispatchQueue(label: "trano.remote.activity", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var retryAfter: [String: Date] = [:]
    init(runtime: TerminalRuntime) {
        self.runtime = runtime
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(15), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume(); self.timer = timer
    }
    deinit { timer?.cancel() }
    private func refresh() {
        guard let state = try? runtime.state() else { return }
        let hosts = Set(state.sessions.compactMap { $0.remote?.hostID })
        for id in hosts where (retryAfter[id] ?? .distantPast) <= Date() {
            do { try runtime.syncRemoteHost(id); retryAfter.removeValue(forKey: id) }
            catch { retryAfter[id] = Date().addingTimeInterval(60) }
        }
    }
}

@MainActor enum BackgroundService {
    static var helperBundle: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Trano Service.app") }

    static func start(runtime: TerminalRuntime) {
        let executable = helperBundle.appendingPathComponent("Contents/MacOS/TranoApp")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try ServiceHandoff.ensure(runtime: runtime, executable: executable)
                try? FileManager.default.removeItem(at: runtime.root.appendingPathComponent("service-diagnostic"))
            } catch {
                try? TerminalRuntime.atomicWrite(Data((error.localizedDescription + "\n").utf8), to: runtime.root.appendingPathComponent("service-diagnostic"))
            }
        }
    }
}
