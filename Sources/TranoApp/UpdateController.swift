import AppKit
import Combine
import Sparkle
import TerminalCore

@MainActor final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateController()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var status = "Updates are not configured for this build."
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()
    private var developerPreferences = DeveloperPreferences()
    private lazy var automaticInstallation = PendingAutomaticUpdateInstall(ready: { [weak self] in
        self?.automaticInstallationIsReady == true
    })
    private var automaticInstallObservers: [NSObjectProtocol] = []
    var automaticInstallInputIsSafe: () -> Bool = { true }

    func applyDeveloperPreferences(_ preferences: DeveloperPreferences) {
        developerPreferences = preferences
        if !preferences.installUpdatesAutomatically {
            automaticInstallation.pause()
            if automaticInstallation.hasPendingInstall { status = "A downloaded update is waiting. Automatic installation is paused until enabled again or Trano quits." }
        } else {
            if automaticInstallation.hasPendingInstall { status = "A downloaded update will install when Trano is not in use." }
            automaticInstallation.resume()
        }
        guard let updater = controller?.updater else { return }
        let readiness = DeveloperUpdatePolicy.resolve(preferences, info: Bundle.main.infoDictionary ?? [:], inheritedAutomaticDownloads: updater.automaticallyDownloadsUpdates)
        guard readiness.available else { status = readiness.reason; return }
        updater.automaticallyDownloadsUpdates = readiness.automaticDownloads
        attemptAutomaticInstall()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        developerPreferences.updateChannel == .bleedingEdge ? ["bleeding-edge"] : []
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard developerPreferences.installUpdatesAutomatically else { return false }
        if automaticInstallObservers.isEmpty {
            for name in [NSApplication.didHideNotification, NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
                automaticInstallObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.attemptAutomaticInstall() }
                })
            }
        }
        automaticInstallation.enqueue(attemptImmediately: false, immediateInstallHandler)
        DispatchQueue.main.async { [weak self] in self?.attemptAutomaticInstall() }
        return true
    }

    private func attemptAutomaticInstall() {
        automaticInstallation.readinessDidChange()
    }

    private var automaticInstallationIsReady: Bool {
        let windows = NSApp.windows
        let visible = windows.filter { $0.isVisible && !$0.isMiniaturized }.count
        let busy = NSApp.modalWindow != nil || !automaticInstallInputIsSafe() || windows.contains {
            $0.attachedSheet != nil || ($0.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
        }
        return DeveloperActionPolicy.mayInstallUpdate(preferences: developerPreferences, appHidden: NSApp.isHidden, visibleWindowCount: visible, inputBusy: busy)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func start() {
        guard controller == nil,
              UpdateLaunchPolicy.shouldStart(arguments: CommandLine.arguments, bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        do {
            _ = try UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:])
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            try controller.updater.start()
            self.controller = controller
            applyDeveloperPreferences(developerPreferences)
            controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .assign(to: &$canCheckForUpdates)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &subscriptions)
            controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &subscriptions)
            status = "Signed updates are enabled. Terminal jobs keep running while Trano restarts."
        } catch {
            status = error.localizedDescription
            canCheckForUpdates = false
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        automaticInstallation.cancel()
        status = error.localizedDescription
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "Trano \(item.displayVersionString) is available."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = "You are running the latest version of Trano."
    }
}
