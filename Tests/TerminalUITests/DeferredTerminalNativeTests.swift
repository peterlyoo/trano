import AppKit
import XCTest
import Speech
@testable import TerminalCore
@testable import SwiftTerm
@testable import TranoApp

@MainActor private final class DeferredInputWindow: NSWindow {
    var acceptsNativeInput = true
    override var isVisible: Bool { true }
    override var isKeyWindow: Bool { acceptsNativeInput }
}

@MainActor final class DeferredTerminalNativeTests: XCTestCase {
    func testNativeTargetBindsActualRendererWindowLeaseAndBackendWithoutAJob() throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: { true }))
        XCTAssertEqual(target.attempt.readiness(target.state()), .ready)
        f.window.acceptsNativeInput = false
        XCTAssertEqual(target.attempt.readiness(target.state()), .cancelled)
        f.window.acceptsNativeInput = true
        f.view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(target.attempt.readiness(target.state()), .cancelled)
        f.view.unmarkText()
        XCTAssertEqual(target.attempt.readiness(target.state()), .cancelled)
    }
    func testVoicePreparationAcceptsOnlyItsExactOwnedToolPanelWithoutAModal() throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, preparingVoice: true, applicationActive: { true }))
        let panel = DeferredInputWindow(contentRect: f.window.frame, styleMask: [], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        f.window.addChildWindow(panel, ordered: .above)
        defer { f.window.removeChildWindow(panel); panel.close() }
        XCTAssertTrue(target.permitsVoicePreparation(in: panel))
        let other = DeferredInputWindow(contentRect: f.window.frame, styleMask: [], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; defer { other.close() }
        XCTAssertFalse(target.permitsVoicePreparation(in: other))
        panel.acceptsNativeInput = false
        XCTAssertFalse(target.permitsVoicePreparation(in: panel))
        panel.acceptsNativeInput = true
        f.store.sessions[0].pid += 1
        XCTAssertFalse(target.permitsVoicePreparation(in: panel))
    }
    func testNativeTargetCannotBecomeCurrentAfterRendererBackendOrGenerationReplacement() throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: { true }))
        f.store.sessions[0].pid += 1
        XCTAssertNil(target.state())
        XCTAssertFalse(target.insert("must not send"))
        XCTAssertFalse(target.attempt.consumed)
    }
    func testUploadChecksBackendBeforeAndAfterFakeRemoteWorkAndDoesNotReroute() throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: { true }))
        var uploads = 0
        XCTAssertThrowsError(try target.upload.save(Data(), runtime: f.runtime, uploader: { _, host, remote in
            uploads += 1; XCTAssertNil(host); XCTAssertNil(remote)
            try f.runtime.update { $0.sessions[0].pid += 1 }
            return "/fake/original.png"
        }))
        XCTAssertEqual(uploads, 1)
        XCTAssertThrowsError(try target.upload.save(Data(), runtime: f.runtime, uploader: { _, _, _ in uploads += 1; return "/fake/wrong.png" }))
        XCTAssertEqual(uploads, 1)
    }
    func testUploadCancellationDuringFakeWorkDropsCompletionAndPreventsInsert() throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: { true }))
        XCTAssertThrowsError(try target.upload.save(Data(), runtime: f.runtime, uploader: { _, _, _ in target.attempt.lease.invalidate(); return "/fake/image.png" }))
        XCTAssertFalse(target.insert("must not send"))
    }
    func testFakeUploadUsesFrozenRemoteHostAndSessionAndRejectsAReconfiguredHost() throws {
        let f = try fixture(); defer { f.cleanup() }
        let host = try RemoteHost(name: "Fixture", address: "fixture-host")
        let remote = RemoteReference(hostID: host.id, sessionID: UUID().uuidString.lowercased())
        var pane = f.pane; pane.remote = remote
        try f.runtime.update { $0.sessions = [pane]; $0.remoteHosts = [host] }
        let owner = TerminalInteractionOwner(paneID: pane.id, windowID: ObjectIdentifier(f.window), generation: UUID())
        let target = DeferredTerminalUploadTarget(paneID: pane.id, backendPID: pane.pid, remote: remote, host: host,
            lease: TerminalInteractionLease(owner: owner, sessionPID: pane.pid, hostID: host.id), providerGeneration: nil, providerPID: nil)
        var uploads = 0
        XCTAssertThrowsError(try target.save(Data(), runtime: f.runtime, uploader: { _, actualHost, actualRemote in
            uploads += 1; XCTAssertEqual(actualHost, host); XCTAssertEqual(actualRemote, remote)
            try f.runtime.update { $0.remoteHosts[0].address = "replacement-host" }
            return "/fake/original-remote.png"
        }))
        XCTAssertEqual(uploads, 1)
        XCTAssertThrowsError(try target.save(Data(), runtime: f.runtime, uploader: { _, _, _ in XCTFail("Rerouted upload to changed host"); return "/fake/replacement.png" }))
    }

    func testVoicePermissionCallbackRevalidatesSourceBeforeRecordingWithoutUsingMicrophone() async {
        var speech: ((SFSpeechRecognizerAuthorizationStatus) -> Void)?
        var valid = true; var microphones = 0
        let voice = VoiceInput(authorizeSpeech: { speech = $0 }, authorizeMicrophone: { _ in microphones += 1 })
        voice.canBeginRecording = { valid }
        voice.text = "newer draft"
        voice.start(); valid = false
        speech?(.authorized)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(microphones, 0)
        XCTAssertFalse(voice.listening); XCTAssertEqual(voice.text, "newer draft")
    }
    func testMicrophoneApprovalRevalidatesSourceBeforeCreatingAnyAudioEngine() async {
        var speech: ((SFSpeechRecognizerAuthorizationStatus) -> Void)?
        var microphone: ((Bool) -> Void)?; var valid = true
        let voice = VoiceInput(authorizeSpeech: { speech = $0 }, authorizeMicrophone: { microphone = $0 })
        voice.canBeginRecording = { valid }; voice.text = "retained draft"
        voice.start(); speech?(.authorized)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNotNil(microphone)
        valid = false; microphone?(true)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(voice.listening); XCTAssertFalse(voice.authorizing)
        XCTAssertEqual(voice.text, "retained draft"); XCTAssertNotNil(voice.error)
    }
    func testNewVoicePresentationCannotReceiveOldAttemptOrHaveItsStateCleared() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: { true }))
        let old = UUID(); f.store.voiceInputPresentationID = old
        target.completeVoice("old input", presentationID: old, closingSheet: nil)
        let newer = UUID(); f.store.voiceInputPresentationID = newer
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(target.attempt.consumed)
        XCTAssertEqual(f.store.voiceInputPresentationID, newer)
        XCTAssertFalse(f.store.showVoice)
    }

    func testProviderReplacementWithinTheSameShellCancelsNativeAndUploadAdmission() throws {
        let f = try fixture(); defer { f.cleanup() }
        let launch = AgentLaunch(paneID: f.pane.id, provider: .codex, cwd: f.root.path, accountID: nil,
                                 configurationRoot: f.root.path, bootID: "fixture", processID: nil, providerPID: 70)
        f.store.state.agentLaunches = [launch]; try f.runtime.update { $0.agentLaunches = [launch] }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: { true }))
        var changed = launch; changed.id = UUID().uuidString.lowercased(); changed.providerPID = 71
        f.store.state.agentLaunches = [changed]; try f.runtime.update { $0.agentLaunches = [changed] }
        XCTAssertEqual(target.attempt.readiness(target.state()), .cancelled)
        XCTAssertThrowsError(try target.upload.save(Data(), runtime: f.runtime, uploader: { _, _, _ in return "/fake/new-provider.png" }))
    }

    func testNewVoicePresentationRevokesOldPermissionCallbacksWithoutClearingNewDraft() async {
        var callbacks: [(SFSpeechRecognizerAuthorizationStatus) -> Void] = []; var microphones = 0
        let voice = VoiceInput(authorizeSpeech: { callbacks.append($0) }, authorizeMicrophone: { _ in microphones += 1 })
        voice.bind(to: UUID()); voice.start()
        voice.bind(to: UUID()); voice.text = "new presentation draft"
        callbacks[0](.authorized)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(microphones, 0); XCTAssertFalse(voice.authorizing)
        XCTAssertFalse(voice.listening); XCTAssertEqual(voice.text, "new presentation draft")
    }

    func testSlowFakeUploadDoesNotBlockUnrelatedTerminalOperationsOrHoldRuntimeLock() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: { true }))
        let upload = target.upload, runtime = f.runtime
        let started = expectation(description: "fake upload started")
        let progressed = expectation(description: "terminal operation completed during upload")
        let finished = expectation(description: "fake upload finished")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        f.store.attachmentQueue.async {
            _ = try? upload.save(Data(), runtime: runtime, uploader: { _, _, _ in
                started.fulfill(); _ = release.wait(timeout: .now() + 2); return "/fake/image.png"
            })
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        f.store.queue.async {
            _ = try? runtime.transaction { try runtime.state() }
            progressed.fulfill()
        }
        await fulfillment(of: [progressed], timeout: 0.3)
        release.signal()
        await fulfillment(of: [finished], timeout: 1)
    }

    func testAnOldVoiceEditorCannotOverwriteTheNewPresentationDraft() {
        let voice = VoiceInput(authorizeSpeech: { _ in XCTFail("No authorization") }, authorizeMicrophone: { _ in XCTFail("No microphone") })
        let old = UUID(), newer = UUID()
        voice.bind(to: old); voice.setDraft("old", for: old)
        voice.bind(to: newer); voice.setDraft("new draft", for: newer)
        voice.setDraft("stale editor commit", for: old)
        XCTAssertEqual(voice.text, "new draft")
    }

    @MainActor private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let pane: TerminalSession
        let view: TranoView
        let window: DeferredInputWindow
        func cleanup() { view.invalidateTerminalInteractions(); view.frameDriver.invalidate(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
    }
    private func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-deferred-unit-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let id = UUID().uuidString.lowercased(); let pane = TerminalSession(id: id, title: "Fixture", cwd: root.path, pid: 4711)
        try runtime.update { $0.sessions = [pane] }
        let binding = SupervisorBinding(paneID: id, backendPID: pane.pid, configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
        let store = AppStore(runtime: runtime, externalBinding: binding); store.sessions = [pane]; store.state.sessions = [pane]; store.loading = false
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 320, height: 160)); view.frameDriver.invalidate()
        store.terminalViews[id] = view; view.store = store; view.paneID = id
        let window = DeferredInputWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        return Fixture(root: root, runtime: runtime, store: store, pane: pane, view: view, window: window)
    }
}
