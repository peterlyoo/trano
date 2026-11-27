import AppKit
import XCTest
@testable import TerminalCore
@testable import SwiftTerm
@testable import TranoApp

@MainActor private final class AttachmentAdmissionWindow: NSWindow {
    override var isVisible: Bool { true }
    override var isKeyWindow: Bool { true }
}
private final class AttachmentAdmissionGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let lock = NSLock(); private var calls = 0
    func enter() -> Int {lock.lock();defer {lock.unlock()};calls += 1;return calls}
    var count: Int {lock.lock();defer {lock.unlock()};return calls}
}
@MainActor final class AttachmentAdmissionNativeTests: XCTestCase {
    func testActualStoreConsumerBoundsHeldImagesBeforeEnqueueAndReleasesCancelledWork() async throws {
        let f = try fixture();defer {f.cleanup()}
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store:f.store,paneID:f.pane.id,applicationActive:{true}))
        let gate = AttachmentAdmissionGate(), started = expectation(description:"fake image work started")
        defer {gate.release.signal()}
        let data = Data(repeating:0,count:20 * 1_048_576)
        let save: @Sendable (Data,DeferredTerminalUploadTarget,TerminalRuntime) throws -> String = {_,_,_ in
            if gate.enter() == 1 {started.fulfill();_ = gate.release.wait(timeout:.now()+2)}
            throw DeferredTerminalInputError.cancelled
        }
        XCTAssertTrue(f.store.enqueueImage(data,target:target,save:save))
        await fulfillment(of:[started],timeout:1)
        XCTAssertTrue(f.store.enqueueImage(data,target:target,save:save))
        XCTAssertFalse(f.store.enqueueImage(data,target:target,save:save))
        XCTAssertEqual(f.store.attachmentAdmission.usage,.init(count:2,bytes:40 * 1_048_576))
        XCTAssertTrue(f.store.message?.contains("Try") == true)
        XCTAssertFalse(f.store.enqueueImage(Data(repeating:0,count:20 * 1_048_576+1),target:target,save:save))
        XCTAssertEqual(gate.count,1)
        gate.release.signal();await drain(f.store)
        XCTAssertEqual(gate.count,2)
        XCTAssertEqual(f.store.attachmentAdmission.usage,.init(count:0,bytes:0))
        XCTAssertFalse(target.attempt.consumed)
    }
    func testActualStoreConsumerReleasesFailureAndDoesNotNotifyAfterOriginalRendererLeaseChanges() async throws {
        struct Failure: Error {}
        let f = try fixture();defer {f.cleanup()}
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store:f.store,paneID:f.pane.id,applicationActive:{true}))
        let gate = AttachmentAdmissionGate(), started = expectation(description:"fake failing image work started")
        defer {gate.release.signal()}
        XCTAssertTrue(f.store.enqueueImage(Data([1]),target:target,save:{_,_,_ in
            started.fulfill();_ = gate.release.wait(timeout:.now()+2);throw Failure()
        }))
        await fulfillment(of:[started],timeout:1)
        target.attempt.lease.invalidate();gate.release.signal();await drain(f.store)
        XCTAssertNil(f.store.message)
        XCTAssertEqual(f.store.attachmentAdmission.usage,.init(count:0,bytes:0))
        XCTAssertFalse(target.attempt.consumed)
    }
    private func drain(_ store:AppStore) async {
        let queue=store.attachmentQueue
        await withCheckedContinuation { continuation in queue.async {continuation.resume()} }
        try? await Task.sleep(for:.milliseconds(20))
    }
    @MainActor private struct Fixture {
        let root:URL;let store:AppStore;let pane:TerminalSession;let view:TranoView;let window:AttachmentAdmissionWindow
        func cleanup() {view.invalidateTerminalInteractions();view.frameDriver.invalidate();window.contentView=nil;window.close();try? FileManager.default.removeItem(at:root)}
    }
    private func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("t-ab-"+UUID().uuidString.prefix(8))
        let runtime=try TerminalRuntime(root:root)
        let pane=TerminalSession(id:UUID().uuidString.lowercased(),title:"Fixture",cwd:root.path,pid:4711)
        try runtime.update {$0.sessions=[pane]}
        let binding=SupervisorBinding(paneID:pane.id,backendPID:pane.pid,configuration:SupervisorConfiguration(provider:.claude,cwd:root.path))
        let store=AppStore(runtime:runtime,externalBinding:binding);store.sessions=[pane];store.state.sessions=[pane];store.loading=false
        let view=TranoView(frame:NSRect(x:0,y:0,width:320,height:160));view.frameDriver.invalidate()
        store.terminalViews[pane.id]=view;view.store=store;view.paneID=pane.id
        let window=AttachmentAdmissionWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=view
        XCTAssertTrue(window.makeFirstResponder(view))
        return Fixture(root:root,store:store,pane:pane,view:view,window:window)
    }
}
