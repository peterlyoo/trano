import Foundation
import TerminalCore

final class AccountUsageWorker {
    private let runtime: TerminalRuntime
    private let interval: TimeInterval
    private let refreshAccount: (String) throws -> Void
    private let queue = DispatchQueue(label: "trano.account.usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(runtime: TerminalRuntime, interval: TimeInterval = 60, refresh: ((String) throws -> Void)? = nil) {
        self.runtime = runtime
        self.interval = interval.isFinite ? max(60, interval) : 60
        refreshAccount = refresh ?? { _ = try runtime.refreshAccountUsage(accountID: $0) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: self.interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    private func poll() {
        guard let accounts = try? runtime.state().accounts else { return }
        let cached = (try? runtime.accountUsage()) ?? []
        for account in accounts where account.enabled && account.provider == .codex {
            if let snapshot = cached.first(where: { $0.accountID == account.id && $0.provider == account.provider }) {
                let age = Date().timeIntervalSince(snapshot.observedAt)
                if age >= 0 && age < interval { continue }
            }
            try? refreshAccount(account.id)
        }
    }
}
