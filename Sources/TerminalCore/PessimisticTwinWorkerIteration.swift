import Foundation

struct TwinWorkerIteration {
    let active: () -> Bool
    let load: () throws -> [TwinRun]
    let scopes: () -> Set<String>
    let startScope: (TwinRun) throws -> Void
    let stopScope: (String) -> Void
    let inspectReview: (TwinRun) throws -> Void
    let hold: (TwinRun, String) throws -> Bool
    let diagnostic: (String) -> Void
    let advance: () throws -> Void

    func run() throws {
        guard active() else { return }
        let runs = try load().filter(\.isActive)
        let ids = Set(runs.map(\.id))
        for id in scopes().subtracting(ids).sorted() {
            guard active() else { return }
            stopScope(id)
        }
        for run in runs {
            guard active() else { return }
            do {
                if !scopes().contains(run.id), ![.needsReview, .conflict, .cleaning].contains(run.phase) {
                    try startScope(run)
                    guard active() else { stopScope(run.id); return }
                }
                if run.phase == .reviewing { try inspectReview(run) }
            } catch {
                guard active() else { return }
                let message = Self.boundedMessage("Twin \(run.id) needs review: " + error.localizedDescription)
                if try hold(run, message) { diagnostic(message) }
            }
        }
        guard active() else { return }
        try advance()
    }

    static func heldRun(current: TwinRun, expected: TwinRun, message: String, now: Date) -> TwinRun? {
        guard current.id == expected.id, current.source == expected.source,
              current.currentRound == expected.currentRound, current.phase == expected.phase,
              current.operation == expected.operation, current.exitReason == expected.exitReason,
              ![.needsReview, .conflict, .finished].contains(current.phase),
              current.latestRound?.snapshot == expected.latestRound?.snapshot,
              samePane(current.latestRound?.pane, expected.latestRound?.pane) else { return nil }
        var held = current
        held.phase = .needsReview; held.message = boundedMessage(message); held.updatedAt = now
        return held
    }
    private static func samePane(_ first: TwinPaneBinding?, _ second: TwinPaneBinding?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case (.some(let first), .some(let second)): return first.matchesProcess(second)
        default: return false
        }
    }
    static func boundedMessage(_ message: String) -> String {
        String(String.UnicodeScalarView(message.unicodeScalars.filter { $0.value != 0 }.prefix(900)))
    }
}
