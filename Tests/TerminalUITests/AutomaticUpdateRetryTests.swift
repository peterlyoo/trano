import XCTest
@testable import TranoApp

@MainActor final class AutomaticUpdateRetryTests: XCTestCase {
    @MainActor private final class Scheduler {
        struct Job { var active = true; let run: @MainActor () -> Void }
        var jobs: [Job] = []
        var active: Int { jobs.filter(\.active).count }
        func schedule(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            let index = jobs.count
            jobs.append(Job(run: action))
            return { [weak self] in self?.jobs[index].active = false }
        }
        func fire(_ index: Int) { jobs[index].active = false; jobs[index].run() }
    }

    // Implements: FR-BATCH-2, FR-SET-105
    func testSparkleDelegateCanStoreReadyHandlerUntilItsCallbackReturns() {
        let scheduler = Scheduler()
        var installs = 0
        let pending = PendingAutomaticUpdateInstall(ready: { true }, schedule: scheduler.schedule)
        pending.enqueue(attemptImmediately: false) { installs += 1 }
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(scheduler.active, 0)
        pending.readinessDidChange()
        XCTAssertEqual(installs, 1)
    }

    // Implements: FR-BATCH-2, FR-SET-105
    func testDisablingAutomaticInstallPausesRetriesWithoutDiscardingSparkleCycleOwner() {
        let scheduler = Scheduler()
        var ready = false, installs = 0
        let pending = PendingAutomaticUpdateInstall(ready: { ready }, schedule: scheduler.schedule)
        pending.enqueue { installs += 1 }
        pending.pause()
        ready = true
        scheduler.fire(0)
        pending.readinessDidChange()
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(scheduler.active, 0)
        XCTAssertTrue(pending.hasPendingInstall)
        pending.resume()
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(pending.hasPendingInstall)
    }

    // Implements: FR-BATCH-2, FR-SET-105
    func testRepeatedResumeWhileBusyPreservesTheOneLiveRetry() {
        let scheduler = Scheduler()
        var ready = false, installs = 0
        let pending = PendingAutomaticUpdateInstall(ready: { ready }, schedule: scheduler.schedule)
        pending.enqueue { installs += 1 }
        pending.pause()
        pending.resume()
        pending.resume()
        XCTAssertEqual(scheduler.active, 1)
        XCTAssertEqual(scheduler.jobs.count, 2)
        ready = true
        scheduler.fire(1)
        XCTAssertEqual(installs, 1)
    }

    // Implements: FR-BATCH-2, FR-SET-105
    func testBusyToSafeInstallsWithoutAnotherWindowNotificationExactlyOnce() {
        let scheduler = Scheduler()
        var busy = true, installs = 0
        let pending = PendingAutomaticUpdateInstall(ready: { !busy }, schedule: scheduler.schedule)
        pending.enqueue { installs += 1 }
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(scheduler.active, 1)
        busy = false
        scheduler.fire(0)
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(scheduler.active, 0)
        scheduler.fire(0)
        pending.readinessDidChange()
        XCTAssertEqual(installs, 1)
    }

    // Implements: FR-BATCH-2, FR-SET-105
    func testBusyRetriesKeepOneOutstandingWorkAndCancelDiscardsOldInstall() {
        let scheduler = Scheduler()
        var ready = false, installs = 0
        let pending = PendingAutomaticUpdateInstall(ready: { ready }, schedule: scheduler.schedule)
        pending.enqueue { installs += 1 }
        pending.readinessDidChange()
        XCTAssertEqual(scheduler.jobs.count, 1)
        scheduler.fire(0)
        XCTAssertEqual(scheduler.active, 1)
        pending.cancel()
        ready = true
        scheduler.fire(1)
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(scheduler.active, 0)
    }

    // Implements: FR-BATCH-2, FR-SET-105
    func testReplacementRejectsOldTimerAndReadyInstallDoesNotCreateTimer() {
        let scheduler = Scheduler()
        var ready = false
        var installed: [String] = []
        let pending = PendingAutomaticUpdateInstall(ready: { ready }, schedule: scheduler.schedule)
        pending.enqueue { installed.append("old") }
        pending.enqueue { installed.append("current") }
        ready = true
        scheduler.fire(0)
        XCTAssertTrue(installed.isEmpty)
        scheduler.fire(1)
        XCTAssertEqual(installed, ["current"])
        let count = scheduler.jobs.count
        pending.enqueue { installed.append("ready") }
        XCTAssertEqual(installed, ["current", "ready"])
        XCTAssertEqual(scheduler.jobs.count, count)
        XCTAssertEqual(scheduler.active, 0)
    }
}
