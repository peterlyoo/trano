import XCTest
import Darwin
@testable import TranoCLI

final class TrackedGitCommandTests: XCTestCase {
    // Implements: FR-WT-1, FR-WT-6
    private let ticket=GitTrackingTicket(id:"capture",nonce:"private-nonce")
    func testUnavailableCaptureRequestsExecPassthroughWithoutRunningOrFinishingProxy() {
        let result=TrackedGitCommand.capture(realGit:"/real/git",arguments:["status"],begin:{nil},finish:{_,_,_ in XCTFail("Finished absent capture")},run:{_,_,_ in XCTFail("Proxy should not start");return .init(termination:.exited(0),interrupted:false)})
        XCTAssertNil(result)
    }
    func testTrackedExecutionPreservesArgumentsAndUsesCaptureIDOnlyWithBeforeAfterOrdering() {
        let arguments=["-C","경로 with space","worktree","add","new\nline","'quote'","끝;"]
        var events:[String]=[]
        let result=TrackedGitCommand.capture(realGit:"/path with space/git",arguments:arguments,begin:{events.append("begin");return self.ticket},finish:{ticket,status,interrupted in
            events.append("finish");XCTAssertEqual(ticket,self.ticket);XCTAssertEqual(status,37);XCTAssertFalse(interrupted)
        },run:{git,args,marker in
            events.append("run");XCTAssertEqual(git,"/path with space/git");XCTAssertEqual(args,arguments);XCTAssertEqual(marker,"capture")
            return .init(termination:.exited(37),interrupted:false)
        })
        XCTAssertEqual(result,.exited(37));XCTAssertEqual(events,["begin","run","finish"])
    }
    func testChildSignalAlwaysMarksCaptureInterruptedAndKeepsRealSignalOutcome() {
        let result=TrackedGitCommand.capture(realGit:"/real/git",arguments:[],begin:{self.ticket},finish:{_,status,interrupted in
            XCTAssertEqual(status,128+SIGTERM);XCTAssertTrue(interrupted)
        },run:{_,_,_ in .init(termination:.signaled(SIGTERM),interrupted:false)})
        XCTAssertEqual(result,.signaled(SIGTERM))
    }
    func testHandledInterruptKeepsActualSuccessfulExitButDisallowsSuccessfulCaptureAttribution() {
        let result=TrackedGitCommand.capture(realGit:"/real/git",arguments:[],begin:{self.ticket},finish:{_,status,interrupted in
            XCTAssertEqual(status,0);XCTAssertTrue(interrupted)
        },run:{_,_,_ in .init(termination:.exited(0),interrupted:true)})
        XCTAssertEqual(result,.exited(0))
    }
    func testProxySetupFailureRequestsPassthroughAndNeverFabricatesGitFinish() {
        XCTAssertNil(TrackedGitCommand.capture(realGit:"/real/git",arguments:[],begin:{self.ticket},finish:{_,_,_ in XCTFail("No Git executed")},run:{_,_,_ in nil}))
    }
}
