import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class SupervisorRuntimeBackend: SupervisorBackend {
    private let runtime: TerminalRuntime
    private var pendingBootstraps: [String: SupervisorBootstrapGate] = [:]

    public init(runtime: TerminalRuntime) { self.runtime = runtime }

    public func transaction<T>(_ body: () throws -> T) throws -> T { try runtime.transaction(body) }

    public func observe() throws -> SupervisorObservation {
        let snapshot = try runtime.state()
        let now = Date()
        let limited = try runtime.accountUsage(now: now).filter { usage in
            guard usage.status == .limited else { return false }
            if let reset = usage.retryAt { return reset > now }
            return now.timeIntervalSince(usage.observedAt) <= 300
        }
        let sessions = try runtime.list()
        let binding = try SupervisorStateStore(root: runtime.root).readPublishedBinding()
        var identities: [String: SupervisorProcessIdentity] = [:]
        if let binding, let pane = sessions.first(where: { $0.id == binding.paneID && $0.remote == nil && $0.alive }),
           let identity = SupervisorProcessIdentity.read(pane.pid) { identities[pane.id] = identity }
        let pending = Set(try runtime.decisionInbox().filter { $0.status == "pending" }.map(\.paneID))
        let limitedIDs = Set(limited.map(\.accountID))
        let continuation = try runtime.makeSupervisorContinuationContext(snapshot: snapshot, sessions: sessions, binding: binding,
            pendingDecisionPaneIDs: pending, limitedAccountIDs: limitedIDs, now: now)
        return SupervisorObservation(layout: snapshot.layout, sessions: sessions, launches: snapshot.agentLaunches,
            accounts: snapshot.accounts,
            pendingDecisionPaneIDs: pending, limitedAccountIDs: limitedIDs, backendIdentities: identities, continuationContext: continuation)
    }

    public func createDetached(cwd: String) throws -> TerminalSession {
        guard let helper = runtime.helperExecutable, FileManager.default.isExecutableFile(atPath: helper) else {
            throw TerminalError.invalid("The bundled Trano helper is required to start the Supervisor")
        }
        let gate = try SupervisorBootstrapGate(root: runtime.root)
        let pane = try runtime.create(title: "Supervisor", cwd: cwd, shell: helper,
            arguments: SupervisorBootstrap.arguments(gateName: gate.name, nonce: gate.nonce))
        pendingBootstraps[pane.id] = gate
        return pane
    }

    public func launch(paneID: String, plan: SupervisorLaunchPlan) throws {
        guard let binding = try SupervisorStateStore(root: runtime.root).readPublishedBinding(), binding.paneID == paneID,
              binding.stoppedAt == nil,
              let current = try runtime.list().first(where: { $0.id == paneID }), current.alive,
              current.remote == nil, current.pid == binding.backendPID else {
            throw TerminalError.invalid("Supervisor bootstrap no longer matches its reserved backend")
        }
        let snapshot = try runtime.state()
        guard !(snapshot.layout.tabs + snapshot.layout.closedTabs).contains(where: { $0.panes.contains(paneID) }),
              !snapshot.agentLaunches.contains(where: { $0.paneID == paneID && $0.lifecycle == .active }) else {
            throw TerminalError.invalid("Supervisor bootstrap is already attached to another workflow")
        }
        guard let gate = pendingBootstraps[paneID] else { throw TerminalError.invalid("Supervisor bootstrap is not owned by this launcher") }
        try gate.release(binding: binding, plan: plan)
        pendingBootstraps.removeValue(forKey: paneID)
    }

    public func terminate(paneID: String) throws {
        pendingBootstraps.removeValue(forKey: paneID)
        try runtime.terminate(paneID)
    }

    public func processIdentity(paneID: String, backendPID: Int32) throws -> SupervisorProcessIdentity? {
        guard try runtime.list().contains(where: { $0.id == paneID && $0.pid == backendPID && $0.alive && $0.remote == nil }) else { return nil }
        return SupervisorProcessIdentity.read(backendPID)
    }
}

extension SupervisorRuntimeBackend: SupervisorContinuationBackend {
    public func continuationContext() throws -> SupervisorContinuationContext {
        try observe().continuationContext ?? SupervisorContinuationContext(authority: nil, candidates: [])
    }

    public func reserveAndCommit(_ request: SupervisorContinuationRequest) throws {
        try runtime.transaction {
            let current = try continuationContext()
            let matching = current.candidates.filter { $0.target.paneID == request.offer.target.paneID }
            guard request.authority.isValid, current.authority == request.authority, matching.count == 1,
                  request.offer.target.paneID != request.authority.launch.paneID,
                  matching.first?.offer(now: Date()) == request.offer else {
                throw TerminalError.invalid("Supervisor continuation changed before delivery")
            }
            try runtime.reserveSupervisorContinuation(request.offer) {
                try runtime.commitTerminalAutomaticInput(lease: request.offer.lease, text: request.text)
            }
        }
    }

    public func reviewInput(authority: SupervisorContinuationAuthority, target: SupervisorContinuationIdentity) throws {
        try runtime.transaction {
            let current = try continuationContext()
            let matching = current.candidates.filter { $0.target.paneID == target.paneID }
            guard current.authority == authority, matching.count == 1, matching.first?.target == target else {
                throw TerminalError.invalid("Supervisor review destination changed")
            }
            try runtime.reviewTerminalInput(paneID: target.paneID, generation: target.generation)
        }
    }
}

extension TerminalRuntime {
    public func supervisorCoordinator() -> SupervisorCoordinator<SupervisorRuntimeBackend> {
        SupervisorCoordinator(store: SupervisorStateStore(root: root), backend: SupervisorRuntimeBackend(runtime: self),
                              helperExecutable: helperExecutable ?? "")
    }

    public func supervisorOperations() -> SupervisorCommandOperations {
        let coordinator = supervisorCoordinator()
        return SupervisorCommandOperations(state: { try coordinator.state() },
            start: { try coordinator.start(configuration: $0, instructions: SupervisorInstructions.prompt) },
            stop: { try coordinator.stop(expectedPaneID: $0, expectedBackendPID: $1) },
            continueWork: { try self.supervisorContinuationCoordinator().continueWork($0) },
            watch: { cursor, timeout in
                let source = try SupervisorDirectoryWakeSource(root: self.root)
                return try SupervisorWatcher(source: source, observe: { try coordinator.state() },
                    observeReadiness: { try self.refreshSupervisorInputReadiness(state: $0) }).wait(after: cursor, timeout: timeout)
            })
    }
}

public final class SupervisorDirectoryWakeSource: SupervisorWakeSource {
    #if canImport(Darwin)
    private let root: URL
    private let queue = DispatchQueue(label: "dev.trano.supervisor-watch", qos: .utility)
    private let signal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var rootSource: DispatchSourceFileSystemObject?
    private var inputSource: DispatchSourceFileSystemObject?
    private var inputIdentity: (dev_t, ino_t)?
    private var rootPending = false
    private var inputPending = false
    private var lastInputOnly = false
    private var failure: Error?

    public var inputOnlyWake: Bool { lock.lock(); defer { lock.unlock() }; return lastInputOnly }

    public init(root: URL) throws {
        self.root = root
        guard let opened = try Self.openDirectory(root.path, missingAllowed: false) else {
            throw TerminalError.invalid("Cannot watch the private Supervisor runtime")
        }
        let child: (Int32, stat)?
        do { child = try Self.openDirectory(root.appendingPathComponent("input-state").path, missingAllowed: true) }
        catch { close(opened.0); throw error }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: opened.0,
            eventMask: [.write, .rename, .delete, .revoke, .attrib], queue: queue)
        rootSource = source
        source.setCancelHandler { close(opened.0) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            do { try self.reconcileInputWatch() } catch { self.recordFailure(error) }
            self.record(inputOnly: false)
        }
        if let child { installInput(child) }
        source.resume()
    }

    private static func openDirectory(_ path: String, missingAllowed: Bool) throws -> (Int32, stat)? {
        let descriptor = open(path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, missingAllowed, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw TerminalError.invalid("Cannot watch a Supervisor state directory") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(descriptor)
            throw TerminalError.invalid("Supervisor watch requires private owned directories")
        }
        return (descriptor, info)
    }

    private func reconcileInputWatch() throws {
        guard let opened = try Self.openDirectory(root.appendingPathComponent("input-state").path, missingAllowed: true) else {
            inputSource?.cancel(); inputSource = nil; inputIdentity = nil
            return
        }
        if let identity = inputIdentity, identity.0 == opened.1.st_dev, identity.1 == opened.1.st_ino {
            close(opened.0)
            return
        }
        installInput(opened)
    }

    private func installInput(_ opened: (Int32, stat)) {
        inputSource?.cancel()
        inputIdentity = (opened.1.st_dev, opened.1.st_ino)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: opened.0,
            eventMask: [.write, .rename, .delete, .revoke, .attrib], queue: queue)
        inputSource = source
        source.setCancelHandler { close(opened.0) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if let flags = self.inputSource?.data, !flags.intersection([.rename, .delete, .revoke, .attrib]).isEmpty {
                do { try self.reconcileInputWatch() } catch { self.recordFailure(error) }
            }
            self.record(inputOnly: true)
        }
        source.resume()
    }

    private func recordFailure(_ error: Error) { lock.lock(); failure = error; lock.unlock() }

    private func record(inputOnly: Bool) {
        lock.lock()
        let wake = !rootPending && !inputPending
        if inputOnly { inputPending = true } else { rootPending = true }
        lock.unlock()
        if wake { signal.signal() }
    }

    public func wait(timeout: TimeInterval) throws -> Bool {
        guard timeout.isFinite, timeout > 0, timeout <= 3600 else { throw TerminalError.invalid("Invalid Supervisor wait timeout") }
        guard signal.wait(timeout: .now() + timeout) == .success else {
            lock.lock(); lastInputOnly = false; lock.unlock()
            return false
        }
        lock.lock()
        lastInputOnly = inputPending && !rootPending
        rootPending = false; inputPending = false
        let error = failure
        lock.unlock()
        if let error { throw error }
        return true
    }

    deinit { rootSource?.cancel(); inputSource?.cancel() }
    #else
    public init(root: URL) throws { throw TerminalError.invalid("Native Supervisor file watching is unavailable on this host") }
    public func wait(timeout: TimeInterval) throws -> Bool { throw TerminalError.invalid("Native Supervisor file watching is unavailable on this host") }
    #endif
}
