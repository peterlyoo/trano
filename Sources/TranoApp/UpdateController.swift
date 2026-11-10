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
        status = error.localizedDescription
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "Trano \(item.displayVersionString) is available."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = "You are running the latest version of Trano."
    }
}
