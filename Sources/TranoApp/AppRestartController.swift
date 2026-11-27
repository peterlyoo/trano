import AppKit
import Combine
import TerminalCore

@MainActor final class AppRestartController: ObservableObject {
    static let shared = AppRestartController()
    @Published private(set) var pendingBuild: BuildIdentity?
    private var timer: Timer?
    private let bundleURL: URL
    private let running: BuildIdentity

    init(bundleURL: URL = Bundle.main.bundleURL, running: BuildIdentity = .process) {
        self.bundleURL = bundleURL
        self.running = running
    }

    func start(interval: TimeInterval = 5) {
        guard timer == nil, running.isBundled else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check() {
        let next = InstalledBuildCheck.pendingRestart(bundleURL: bundleURL, running: running)
        if next != pendingBuild { pendingBuild = next }
    }

    /// Relaunches the GUI from the installed bundle. Shells live in the pty-host, so they keep running.
    func restart() {
        check()
        guard pendingBuild != nil else { return }
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", Self.relaunchScript, "trano-relaunch", String(getpid()),
                                bundleURL.appendingPathComponent("Contents/MacOS/TranoApp").path]
            + Self.openArguments(bundleURL: bundleURL, environment: ProcessInfo.processInfo.environment)
        relauncher.standardInput = FileHandle.nullDevice
        relauncher.standardOutput = FileHandle.nullDevice
        relauncher.standardError = FileHandle.nullDevice
        do { try relauncher.run() } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }

    // Waits for this GUI to exit; if LaunchServices refuses the bundle, starts its executable directly so the GUI never stays gone.
    nonisolated static let relaunchScript = """
    pid="$1"; executable="$2"; shift 2
    while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done
    /usr/bin/open "$@" || exec "$executable"
    """

    // LaunchServices does not inherit the caller's environment; carry the data root so the relaunched GUI reattaches to the same sessions.
    nonisolated static func openArguments(bundleURL: URL, environment: [String: String]) -> [String] {
        var arguments = ["-n"]
        for key in ["TRANO_DATA_DIR", "HOME"] { if let value = environment[key] { arguments += ["--env", key + "=" + value] } }
        return arguments + [bundleURL.path]
    }
}
