import AppKit
import TerminalCore

final class BackgroundServerHost {
    private let root: URL
    private let applicationURL: URL
    private let cache: ServerStatusCache
    private var lease: ServerHelperLease?
    private var runtime: TerminalRuntime?
    private var service: APIService?
    private var notifications: NotificationController?
    private let shutdown: () -> Void

    init(root: URL, applicationURL: URL, cache: ServerStatusCache, lease: ServerHelperLease?, shutdown: @escaping () -> Void) {
        self.root = root; self.applicationURL = applicationURL; self.cache = cache; self.lease = lease; self.shutdown = shutdown
    }
    func start() throws {
        if lease == nil { lease = try ServerHelperLease(root: root) }
        let runtime: TerminalRuntime
        if let existing = self.runtime { runtime = existing }
        else {
            runtime = try TerminalRuntime(root: root, helperExecutable: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("trano").path)
            self.runtime = runtime
        }
        runtime.prepareWorktreeTracking()
        let notifications = self.notifications ?? NotificationController(runtime: runtime, applicationURL: applicationURL)
        let service = APIService(runtime: runtime, customHandler: notifications.handle, responseDidSend: notifications.responseDidSend, serverStatus: { [cache] in cache.json() })
        if self.notifications == nil { notifications.onShutdown = shutdown }
        try service.start()
        self.service = service
        if self.notifications == nil { self.notifications = notifications; notifications.start() }
    }
    func restart() throws { service?.stop(); service = nil; try start() }
    func stop() { service?.stop(); service = nil }
}
