import Combine
import Foundation
import TerminalCore

@MainActor final class SessionLoadClientCache: ObservableObject {
    typealias Work = (@escaping () -> Void) -> Void
    @Published private(set) var byPane: [String: SessionLoadSnapshot] = [:]
    private let fetch: () throws -> [SessionLoadSnapshot]
    private let schedule: Work
    private let deliver: Work
    private let clock: () -> Date
    private var pending = false
    private var timer: DispatchSourceTimer?
    private final class WeakCache { weak var cache: SessionLoadClientCache?; init(_ cache: SessionLoadClientCache) { self.cache = cache } }
    private static var sharedCaches: [String: WeakCache] = [:]

    init(initial: [SessionLoadSnapshot] = [], fetch: @escaping () throws -> [SessionLoadSnapshot],
         schedule: Work? = nil, deliver: Work? = nil, clock: @escaping () -> Date = Date.init) {
        self.fetch = fetch; self.clock = clock
        if let schedule { self.schedule = schedule }
        else {
            let queue = DispatchQueue(label: "trano.session-load.client", qos: .utility)
            self.schedule = { queue.async(execute: DispatchWorkItem(block: $0)) }
        }
        self.deliver = deliver ?? { DispatchQueue.main.async(execute: DispatchWorkItem(block: $0)) }
        byPane = Dictionary(initial.map { ($0.paneID, $0.freshened(at: clock())) }, uniquingKeysWith: { first, _ in first })
    }

    static func shared(root: URL) -> SessionLoadClientCache {
        let key = root.standardizedFileURL.path
        if let existing = sharedCaches[key]?.cache { return existing }
        sharedCaches = sharedCaches.filter { $0.value.cache != nil }
        let client = APIClient(path: root.appendingPathComponent("api.sock").path)
        let cache = SessionLoadClientCache(fetch: {
            var snapshots: [SessionLoadSnapshot] = []
            for offset in stride(from: 0, to: 4096, by: 64) {
                let response = try client.call(APIRequest(method: "sessions.load", params: ["offset": .number(Double(offset)), "limit": .number(64)]))
                guard response.error == nil, let value = response.result else { throw TerminalError.runtime("Session load cache is unavailable") }
                let page = try JSONDecoder().decode([SessionLoadSnapshot].self, from: JSONEncoder().encode(value))
                snapshots.append(contentsOf: page)
                if page.count < 64 { break }
            }
            return snapshots
        })
        sharedCaches[key] = WeakCache(cache)
        cache.start()
        return cache
    }

    private func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        self.timer = timer
        timer.resume()
    }

    func refresh() {
        let now = clock()
        let fresh = byPane.mapValues { $0.freshened(at: now) }
        if fresh != byPane { byPane = fresh }
        guard !pending else { return }
        pending = true
        let fetch = fetch, deliver = deliver
        schedule { [weak self] in
            let result = try? fetch()
            deliver { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pending = false
                    guard let result else { return }
                    let now = self.clock()
                    let values = Dictionary(result.prefix(4096).map { ($0.paneID, $0.freshened(at: now)) }, uniquingKeysWith: { first, _ in first })
                    if values != self.byPane { self.byPane = values }
                }
            }
        }
    }

    deinit { timer?.cancel() }
}
