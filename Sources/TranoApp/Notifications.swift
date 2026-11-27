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
    private let nativeSink = NativeNotificationSink()
    private var quotaTimer: DispatchSourceTimer?
    private var quotaLedger: QuotaAlarmLedger?
    private var quotaResetDeadline: Date?
    private var remoteWorker: RemoteActivityWorker?
    private var accountUsageWorker: AccountUsageWorker?
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
        accountUsageWorker = AccountUsageWorker(runtime: runtime)
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
        if let preferences = try NotificationPreferencesAPI.handle(request, runtime: runtime) { return preferences }
        if request.method == "notifications.publish" {
            guard case .string(let rawKind)? = request.params["kind"], let kind = NotificationKind(rawValue: rawKind),
                  [.terminal, .tailscaleSignIn, .tailscaleDeviceApproval, .tailscaleFailure].contains(kind),
                  case .string(let title)? = request.params["title"], case .string(let body)? = request.params["body"] else {
                throw TerminalError.invalid("Choose a typed terminal or network notification")
            }
            let paneID: String?
            if case .string(let value)? = request.params["paneID"] { paneID = value } else { paneID = nil }
            if kind == .terminal {
                guard let paneID, UUID(uuidString: paneID) != nil,
                      case .number(let expectedPID)? = request.params["expectedPID"], expectedPID.isFinite,
                      try runtime.state().sessions.contains(where: { $0.id == paneID && Double($0.pid) == expectedPID }) else {
                    throw TerminalError.invalid("Terminal notification requires an existing pane")
                }
            }
            let message = NotificationMessage(identifier: "\(kind.rawValue).\(UUID().uuidString)", kind: kind, title: title, body: body, paneID: paneID)
            queue.async { [weak self] in
                guard let self, let state = try? self.runtime.state(), let preferences = try? self.runtime.notificationPreferences() else { return }
                self.deliver(message, state: state, preferences: preferences)
            }
            return .object(["accepted": .bool(true)])
        }
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
                self.quotaTimer?.cancel(); self.quotaTimer = nil
                self.remoteWorker = nil
                self.accountUsageWorker = nil
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
        guard let state = try? runtime.state(), let preferences = try? runtime.notificationPreferences() else { return }
        if state.revision != cursor, let batch = try? runtime.events(since: min(cursor, state.revision)) {
            let now = Date()
            let events = ActivityNotificationBacklog.deliverable(batch.events, now: now)
            // The hook names a permission's tool after the screen reports the prompt; the screen reports a turn summary after the hook's completion.
            if let early = ActivityNotificationBacklog.wait(for: events, now: now) {
                pending?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.refresh() }
                pending = work
                queue.asyncAfter(deadline: .now() + early, execute: work)
                return
            }
            let locale = Locale.preferredLanguages.first?.hasPrefix("ko") == true ? "ko" : "en"
            let messages = events.map { event -> NotificationMessage in
                let body: String
                switch event.activity.state {
                case .running: body = "Task started"
                case .done: body = AttentionSummary.completion(reason: event.activity.reason,
                                                               terminalTitle: state.sessions.first { $0.id == event.sessionID }?.terminalTitle)
                case .blocked:
                    let reason = runtime.notificationReason(event.activity, paneID: event.sessionID, locale: locale)
                    body = reason.isEmpty ? "Waiting for your attention" : reason
                default: body = "Task ended with an error"
                }
                return NotificationMessage(identifier: "activity.\(event.sessionID).\(event.revision)", kind: .activity,
                                           title: event.title, body: body, paneID: event.sessionID, activity: event.activity.state)
            }
            deliver(batch: messages, state: state, preferences: preferences)
            cursor = batch.revision
            try? TerminalRuntime.atomicWrite(Data("\(cursor)\n".utf8), to: cursorURL)
        }
        refreshQuota(state: state, preferences: preferences)
    }

    private func refreshQuota(state: RuntimeState, preferences: NotificationPreferences) {
        let store = QuotaAlarmLedgerStore(root: runtime.root)
        if quotaLedger == nil { quotaLedger = try? store.read() }
        guard var ledger = quotaLedger else { return }
        let now = Date()
        let nextReset: Date?
        do {
            nextReset = try QuotaAlarmDispatch.advance(ledger: &ledger, accounts: state.accounts,
                                                       usage: (try? runtime.accountUsage(now: now)) ?? [], preferences: preferences, now: now,
                                                       persist: store.save,
                                                       deliver: { [weak self] notice in
                guard let self, let account = state.accounts.first(where: { $0.id == notice.accountID && $0.enabled }) else { return }
                self.deliver(NotificationMessage.quota(notice, account: account, threshold: preferences.quotaLowRemainingPercent), state: state, preferences: preferences)
            })
        } catch { return }
        quotaLedger = ledger
        guard nextReset != quotaResetDeadline else { return }
        quotaTimer?.cancel(); quotaTimer = nil; quotaResetDeadline = nextReset
        if let reset = nextReset {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + min(31_536_000, max(0.1, reset.timeIntervalSince(now))), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.quotaResetDeadline = nil; self?.refresh() }
            timer.resume(); quotaTimer = timer
        }
    }

    private func deliver(_ message: NotificationMessage, state: RuntimeState, preferences: NotificationPreferences) {
        deliver(batch: [message], state: state, preferences: preferences)
    }

    private func deliver(batch messages: [NotificationMessage], state: RuntimeState, preferences: NotificationPreferences) {
        guard !messages.isEmpty else { return }
        let bundleID = Bundle(url: applicationURL)?.bundleIdentifier ?? "dev.trano.app"
        let active = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: \.isActive)
        let focused = active ? InterfacePresence.focusedPane(root: runtime.root) { pid in
            NSRunningApplication(processIdentifier: pid).map { $0.isActive && $0.bundleIdentifier == bundleID } ?? false
        } : nil
        NotificationDelivery.deliver(batch: messages, preferences: preferences, legacyMasterEnabled: state.settings.notifications,
                                     context: { _ in NotificationContext(applicationActive: active, focusedPaneID: focused) },
                                     system: nativeSink.sendSystem,
                                     inApp: { _, _ in },
                                     sound: nativeSink.playSound)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        NotificationResponseRelay.open(response, applicationURL: applicationURL, completion: completionHandler)
    }
}

/// Which process this launch is. Notification Center relaunches the helper bundle without `--service`
/// to deliver a click on a notification it posted, so the bundle identity also selects the service role.
enum LaunchRole {
    static let helperBundleIdentifier = "dev.trano.activity"
    static var isService: Bool {
        CommandLine.arguments.contains("--service") || Bundle.main.bundleIdentifier == helperBundleIdentifier
    }
}

/// Receives a notification click before the service's NotificationController exists, including in a helper
/// relaunched only to deliver the click while another service instance keeps running.
final class NotificationResponseRelay: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationResponseRelay()
    static var mainApplicationURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func install() { UNUserNotificationCenter.current().delegate = self }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Self.open(response, applicationURL: Self.mainApplicationURL, completion: completionHandler)
    }

    static func sessionURL(_ userInfo: [AnyHashable: Any]) -> URL? {
        guard let id = userInfo["sessionID"] as? String, UUID(uuidString: id) != nil else { return nil }
        return URL(string: "trano://session/" + id)
    }

    static func open(_ response: UNNotificationResponse, applicationURL: URL, completion: @escaping () -> Void) {
        guard let url = sessionURL(response.notification.request.content.userInfo) else { completion(); return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in completion() }
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
        let bundledHelper = helperBundle
        DispatchQueue.global(qos: .utility).async {
            do {
                let preferences = try DeveloperSettingsStore(root: runtime.root).load()
                let metadata = preferences.installationLocation == .sourceCheckout
                    ? try DeveloperInstallationInspector.sourceBundle(directory: URL(fileURLWithPath: preferences.sourceDirectory))
                    : try DeveloperInstallationInspector.inspect(bundle: bundledHelper)
                let info = metadata.executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
                let expected = try BuildIdentity(metadataURL: info)
                _ = try ServiceHandoff.ensure(runtime: runtime, executable: metadata.executable, expected: expected)
                let response = try APIClient(path: runtime.root.appendingPathComponent("api.sock").path).call(APIRequest(method: "server.info"))
                guard response.error == nil, response.result?["apiVersion"] == .number(Double(metadata.apiVersion)) else {
                    throw TerminalError.invalid("The selected background service has an incompatible API version.")
                }
                try? FileManager.default.removeItem(at: runtime.root.appendingPathComponent("service-diagnostic"))
            } catch {
                try? TerminalRuntime.atomicWrite(Data((error.localizedDescription + "\n").utf8), to: runtime.root.appendingPathComponent("service-diagnostic"))
            }
        }
    }
}
