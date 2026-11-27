import Foundation
import Darwin

protocol SupervisorReadinessWatchToken: AnyObject, Sendable { func cancel() }

@MainActor final class SupervisorReadinessDirectoryWatch {
    typealias MakeWatch = (Int32, @escaping @MainActor (Bool) -> Void, @escaping @Sendable () -> Void) -> SupervisorReadinessWatchToken
    private let root: URL
    private let onChange: @MainActor () -> Void
    private let makeWatch: MakeWatch
    private(set) var isWatching = false
    private var token: SupervisorReadinessWatchToken?
    private var stopped = false

    init(root: URL, onChange: @escaping @MainActor () -> Void, makeWatch: MakeWatch? = nil) {
        self.root = root; self.onChange = onChange
        self.makeWatch = makeWatch ?? Self.nativeWatch
    }
    func reconcile() {
        guard !stopped, token == nil else { return }
        let descriptor = open(root.appendingPathComponent("input-state").path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { close(descriptor); return }
        token = makeWatch(descriptor, { [weak self] reset in
            guard let self, !self.stopped else { return }
            if reset { self.token?.cancel(); self.token = nil; self.isWatching = false; self.reconcile() }
            self.onChange()
        }, { close(descriptor) })
        isWatching = true
    }
    func stop() { stopped = true; token?.cancel(); token = nil; isWatching = false }
    deinit { token?.cancel() }

    private static func nativeWatch(_ descriptor: Int32, event: @escaping @MainActor (Bool) -> Void,
                                    closed: @escaping @Sendable () -> Void) -> SupervisorReadinessWatchToken {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .revoke], queue: .main)
        source.setEventHandler {
            let reset = !source.data.intersection([.rename, .delete, .attrib, .revoke]).isEmpty
            MainActor.assumeIsolated { event(reset) }
        }
        source.setCancelHandler(handler: closed)
        source.resume()
        return NativeToken(source)
    }
}

private final class NativeToken: SupervisorReadinessWatchToken, @unchecked Sendable {
    let source: DispatchSourceFileSystemObject
    init(_ source: DispatchSourceFileSystemObject) { self.source = source }
    func cancel() { source.cancel() }
    deinit { source.cancel() }
}
