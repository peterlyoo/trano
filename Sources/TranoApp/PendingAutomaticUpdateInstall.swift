import Foundation

@MainActor final class PendingAutomaticUpdateInstall {
    typealias Schedule = @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    private let ready: () -> Bool
    private let schedule: Schedule
    private var pending: (() -> Void)?
    private var cancelRetry: (@MainActor () -> Void)?
    private var generation = UUID()
    private var paused = false
    var hasPendingInstall: Bool { pending != nil }

    init(ready: @escaping () -> Bool, schedule: @escaping Schedule = PendingAutomaticUpdateInstall.scheduleRetry) {
        self.ready = ready
        self.schedule = schedule
    }

    func enqueue(attemptImmediately: Bool = true, _ install: @escaping () -> Void) {
        cancel()
        pending = install
        if attemptImmediately { readinessDidChange() }
    }

    func cancel() {
        generation = UUID()
        pending = nil
        paused = false
        cancelRetry?()
        cancelRetry = nil
    }

    func pause() {
        paused = true
        generation = UUID()
        cancelRetry?()
        cancelRetry = nil
    }

    func resume() {
        paused = false
        readinessDidChange()
    }

    func readinessDidChange() {
        guard !paused, let install = pending else { return }
        if ready() {
            cancel()
            install()
            return
        }
        guard cancelRetry == nil else { return }
        let token = generation
        cancelRetry = schedule { [weak self] in
            guard let self, self.generation == token, self.pending != nil else { return }
            self.cancelRetry = nil
            self.readinessDidChange()
        }
    }

    private static func scheduleRetry(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1), execute: work)
        return { work.cancel() }
    }

}
