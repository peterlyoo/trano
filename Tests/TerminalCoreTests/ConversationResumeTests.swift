import Foundation
import XCTest
@testable import TerminalCore

final class ConversationResumeTests: XCTestCase {
    let sessionID = "33333333-3333-4333-8333-333333333333"
    let paneID = "44444444-4444-4444-8444-444444444444"
    func conversation(accountID: String? = nil, root: String = "/tmp/provider", cwd: String = "/tmp/한글 space 'quoted';") -> AgentConversation {
        AgentConversation(source: ConversationHistorySource(id: "source", provider: .codex, configurationRoot: root, accountID: accountID, label: "Account"), providerSessionID: sessionID, title: "Korean 작업", cwd: cwd, updatedAt: Date(timeIntervalSince1970: 1), relativePath: "sessions/rollout-" + sessionID + ".jsonl")
    }
    func context(_ entry: AgentConversation, launch: AgentLaunch? = nil, supervisor: Bool = false) -> ConversationResumeContext {
        var state = RuntimeState(); let workspace = state.layout.addWorkspace(title: "quiet-forest")
        let pane = TerminalSession(id: paneID, title: "Existing", cwd: entry.cwd, pid: 123)
        state.sessions = [pane]; _ = state.layout.addTab(paneID: paneID)
        XCTAssertEqual(state.layout.selectedWorkspaceID, workspace)
        if let launch { state.agentLaunches = [launch] }
        return ConversationResumeContext(state: state, livePaneIDs: [paneID], sources: [entry.source], supervisorPaneID: supervisor ? paneID : nil)
    }
    func launch(_ entry: AgentConversation, root: String? = nil) -> AgentLaunch {
        AgentLaunch(paneID: paneID, provider: entry.source.provider, providerSessionID: sessionID, cwd: entry.cwd, accountID: entry.source.accountID, configurationRoot: root ?? entry.source.configurationRoot, bootID: "boot", processID: nil)
    }
    final class Calls { var values: [String] = [] }
    func operations(_ entry: AgentConversation, context: ConversationResumeContext, calls: Calls, failure: String? = nil) -> ConversationResumeOperations {
        ConversationResumeOperations(context: { context }, validate: { value in calls.values.append("validate"); if failure == "validate" { throw TerminalError.invalid("Stale history") }; return value }, create: { value in
            calls.values.append("create"); XCTAssertEqual(value.cwd.utf8.map{$0}, entry.cwd.utf8.map{$0})
            return TerminalSession(id: "55555555-5555-4555-8555-555555555555", title: value.title, cwd: value.cwd, pid: 456)
        }, stage: { value, pane, workspace in
            calls.values.append("stage"); XCTAssertEqual(workspace, context.state.layout.selectedWorkspaceID)
            if failure == "stage" { throw TerminalError.invalid("Workspace vanished") }
            return AgentLaunch(paneID: pane.id, provider: value.source.provider, providerSessionID: value.providerSessionID, cwd: value.cwd, accountID: value.source.accountID, configurationRoot: value.source.configurationRoot, bootID: "boot", processID: nil)
        }, launch: { pane, binding in
            calls.values.append("launch"); XCTAssertEqual(binding.providerSessionID, self.sessionID); XCTAssertNotEqual(pane.id, self.paneID)
            if failure == "launch" { throw TerminalError.invalid("Launch failed") }
        }, open: { value in calls.values.append("open:"+value) }, rollback: { value in calls.values.append("rollback:"+value) })
    }
    // Implements: FR-RESUME-1, FR-RESUME-4, FR-RESUME-5
    func testSourcesRetainAccountIdentityAndCannotPromoteDeletedManagedAccounts() {
        let account = AccountProfile(provider: .codex, label: "Org A")
        var state = RuntimeState(); state.accounts = [account]
        let root = URL(fileURLWithPath: "/tmp/runtime"), home = URL(fileURLWithPath: "/tmp/home")
        state.agentLaunches = [AgentLaunch(paneID: paneID, provider: .codex, providerSessionID: sessionID, cwd: "/tmp/project", accountID: UUID().uuidString, configurationRoot: "/tmp/deleted-account", bootID: "boot")]
        let sources = ConversationHistorySources.build(state: state, runtimeRoot: root, home: home, environment: ["CODEX_HOME":"/tmp/codex3"])
        XCTAssertEqual(sources.count,4)
        XCTAssertEqual(sources.first?.accountID,account.id)
        XCTAssertEqual(sources.first?.configurationRoot,"/tmp/runtime/accounts/"+account.id)
        XCTAssertTrue(sources.contains { $0.configurationRoot == "/tmp/codex3" && $0.accountID == nil })
        XCTAssertFalse(sources.contains { $0.configurationRoot == "/tmp/deleted-account" })
        let again = ConversationHistorySources.build(state: state, runtimeRoot: root, home: home, environment: ["CODEX_HOME":"/tmp/codex3"])
        XCTAssertEqual(sources,again)
    }
    // Implements: FR-RESUME-4, FR-RESUME-5
    func testRevokedSourceDisabledAccountAndChangedCWDRejectBeforeCreation() throws {
        let entry=conversation(),original=context(conversation())
        let missing=ConversationResumeContext(state:original.state,livePaneIDs:original.livePaneIDs,sources:[])
        let disabled=ConversationHistorySource(id:entry.source.id,provider:.codex,configurationRoot:entry.source.configurationRoot,label:"Account",enabled:false)
        let disabledContext=ConversationResumeContext(state:original.state,livePaneIDs:[],sources:[disabled])
        for ctx in [missing,disabledContext] {
            let calls=Calls()
            XCTAssertThrowsError(try ConversationResumeCoordinator.resume(entry,workspaceID:ctx.state.layout.selectedWorkspaceID,operations:operations(entry,context:ctx,calls:calls)))
            XCTAssertFalse(calls.values.contains("create"))
        }
        let calls=Calls();var ops=operations(entry,context:original,calls:calls)
        ops.validate={ _ in self.conversation(cwd:"/tmp/different") }
        XCTAssertThrowsError(try ConversationResumeCoordinator.resume(entry,workspaceID:original.state.layout.selectedWorkspaceID,operations:ops))
        XCTAssertTrue(calls.values.isEmpty)
    }
    // Implements: FR-RESUME-5
    func testCancelledAndFaultyCreateNeverRollBackAnExistingPane() throws {
        let entry=conversation(),ctx=context(conversation()),calls=Calls()
        var ops=operations(entry,context:ctx,calls:calls);ops.isCancelled={true}
        XCTAssertThrowsError(try ConversationResumeCoordinator.resume(entry,workspaceID:ctx.state.layout.selectedWorkspaceID,operations:ops))
        XCTAssertTrue(calls.values.isEmpty)
        ops.isCancelled={false};ops.create={_ in ctx.state.sessions[0]}
        XCTAssertThrowsError(try ConversationResumeCoordinator.resume(entry,workspaceID:ctx.state.layout.selectedWorkspaceID,operations:ops))
        XCTAssertFalse(calls.values.contains("rollback:"+paneID))
    }
    // Implements: FR-RESUME-4, FR-RESUME-5
    func testNewConversationUsesNewPaneAndExactIdentityWithoutTouchingExistingJob() throws {
        let entry=conversation(), ctx=context(conversation()), calls=Calls()
        let result=try ConversationResumeCoordinator.resume(entry, workspaceID: ctx.state.layout.selectedWorkspaceID, operations: operations(entry, context: ctx, calls: calls))
        XCTAssertFalse(result.existing); XCTAssertNotEqual(result.paneID, paneID)
        XCTAssertEqual(calls.values, ["validate","create","stage","launch"])
    }
    // Implements: FR-RESUME-4, FR-RESUME-5
    func testExactLiveConversationNavigatesWithoutCreatingOrSending() throws {
        let entry=conversation(), ctx=context(conversation(), launch: launch(conversation())), calls=Calls()
        let result=try ConversationResumeCoordinator.resume(entry, workspaceID: ctx.state.layout.selectedWorkspaceID, operations: operations(entry, context: ctx, calls: calls))
        XCTAssertTrue(result.existing); XCTAssertEqual(result.paneID,paneID)
        XCTAssertFalse(calls.values.contains("create")); XCTAssertEqual(calls.values.last,"open:"+paneID)
    }
    // Implements: FR-RESUME-4, FR-RESUME-5
    func testSameProviderUUIDInAnotherAccountRootDoesNotStealLivePane() throws {
        let entry=conversation(), ctx=context(conversation(), launch: launch(conversation(),root:"/tmp/other-account")), calls=Calls()
        let result=try ConversationResumeCoordinator.resume(entry, workspaceID: ctx.state.layout.selectedWorkspaceID, operations: operations(entry, context: ctx, calls: calls))
        XCTAssertFalse(result.existing); XCTAssertTrue(calls.values.contains("create"))
    }
    // Implements: FR-RESUME-4, FR-RESUME-5
    func testSupervisorConversationReturnsNativeOwnerWithoutOrdinaryNavigation() throws {
        let entry=conversation(), ctx=context(conversation(), launch: launch(conversation()),supervisor:true), calls=Calls()
        let result=try ConversationResumeCoordinator.resume(entry, workspaceID:ctx.state.layout.selectedWorkspaceID,operations:operations(entry,context:ctx,calls:calls))
        XCTAssertTrue(result.supervisor); XCTAssertFalse(calls.values.contains("open:"+paneID)); XCTAssertFalse(calls.values.contains("create"))
    }
    // Implements: FR-RESUME-4, FR-RESUME-5
    func testExitedSupervisorConversationStillBelongsToNativePanel() throws {
        let entry=conversation(),original=context(conversation(),launch:launch(conversation()),supervisor:true)
        var state=original.state;state.agentLaunches[0].lifecycle = .exited
        let ctx=ConversationResumeContext(state:state,livePaneIDs:[],sources:original.sources,supervisorPaneID:paneID),calls=Calls()
        let result=try ConversationResumeCoordinator.resume(entry,workspaceID:ctx.state.layout.selectedWorkspaceID,operations:operations(entry,context:ctx,calls:calls))
        XCTAssertTrue(result.supervisor);XCTAssertEqual(result.paneID,paneID)
        XCTAssertFalse(calls.values.contains("create"));XCTAssertFalse(calls.values.contains("open:"+paneID))
    }
    // Implements: FR-RESUME-4, FR-RESUME-5
    func testExplicitSupervisorStopReleasesHistoryForNewPaneWithoutReusingReservedID() throws {
        let entry=conversation(),original=context(conversation(),supervisor:true),calls=Calls()
        let ctx=ConversationResumeContext(state:original.state,livePaneIDs:[],sources:original.sources,supervisorPaneID:paneID)
        let result=try ConversationResumeCoordinator.resume(entry,workspaceID:ctx.state.layout.selectedWorkspaceID,operations:operations(entry,context:ctx,calls:calls))
        XCTAssertFalse(result.supervisor);XCTAssertFalse(result.existing);XCTAssertNotEqual(result.paneID,paneID)
        XCTAssertEqual(calls.values,["validate","create","stage","launch"])
    }
    // Implements: FR-RESUME-4, FR-RESUME-5
    func testBackgroundOrLongPendingOwnedAgentNeverAuthorizesDuplicateFromForegroundPresentation() throws {
        let entry=conversation(),original=context(conversation(),launch:launch(conversation())),calls=Calls()
        var state=original.state;state.agentLaunches[0].updatedAt = Date.distantPast
        var shell=state.sessions[0];shell.foregroundProgram = .zsh
        let ctx=ConversationResumeContext(state:state,sessions:[shell],sources:original.sources)
        let result=try ConversationResumeCoordinator.resume(entry,workspaceID:ctx.state.layout.selectedWorkspaceID,operations:operations(entry,context:ctx,calls:calls))
        XCTAssertTrue(result.existing);XCTAssertFalse(calls.values.contains("create"))
    }
    // Implements: FR-RESUME-3, FR-RESUME-4, FR-RESUME-5
    func testNativeResumeDoesNotBroadcastNavigationIntoAnotherWindow() throws {
        let entry=conversation(),ctx=context(conversation());var state=ctx.state
        let destination=try XCTUnwrap(state.layout.selectedWorkspaceID)
        let otherWorkspace=state.layout.addWorkspace(title:"other-workspace")
        _ = state.layout.addTab(paneID:UUID().uuidString)
        var otherWindow=WindowSelection()
        _ = otherWindow.resolve(state,ownAction:false,acceptsRequests:true)
        let pane=TerminalSession(id:UUID().uuidString,title:entry.title,cwd:entry.cwd,pid:456)
        state.sessions.append(pane)
        _ = try ConversationResumeCoordinator.stage(entry,pane:pane,workspaceID:destination,bootID:"boot",state:&state)
        let other=otherWindow.resolve(state,ownAction:false,acceptsRequests:true)
        XCTAssertEqual(other.layout.selectedWorkspaceID,otherWorkspace)
    }
    // Implements: FR-RESUME-4, FR-RESUME-5
    func testStaleHistoryAndWorkspaceNeverCreate() throws {
        let entry=conversation(),ctx=context(conversation())
        for mode in ["validate","workspace"] {
            let calls=Calls()
            XCTAssertThrowsError(try ConversationResumeCoordinator.resume(entry,workspaceID:mode == "workspace" ? UUID().uuidString : ctx.state.layout.selectedWorkspaceID,operations:operations(entry,context:ctx,calls:calls,failure:mode)))
            XCTAssertFalse(calls.values.contains("create")); XCTAssertFalse(calls.values.contains(where:{$0.hasPrefix("rollback")}))
        }
    }
    // Implements: FR-RESUME-5
    func testFailedStageOrSendRollsBackOnlyNewPane() throws {
        let entry=conversation(),ctx=context(conversation())
        for failure in ["stage","launch"] {
            let calls=Calls()
            XCTAssertThrowsError(try ConversationResumeCoordinator.resume(entry,workspaceID:ctx.state.layout.selectedWorkspaceID,operations:operations(entry,context:ctx,calls:calls,failure:failure)))
            XCTAssertEqual(calls.values.last,"rollback:55555555-5555-4555-8555-555555555555")
            XCTAssertFalse(calls.values.contains("rollback:"+paneID))
        }
    }
    // Implements: FR-RESUME-4, FR-RESUME-5
    func testStageKeepsExistingJobsAndSeedsShortRecoveryWithNoForeignLiveProcessID() throws {
        let entry=conversation(),ctx=context(conversation());var state=ctx.state
        let original=state.sessions[0], oldTab=state.layout.tabs[0]
        let pane=TerminalSession(id:"55555555-5555-4555-8555-555555555555",title:entry.title,cwd:entry.cwd,pid:456)
        state.sessions.append(pane)
        let binding=try ConversationResumeCoordinator.stage(entry,pane:pane,workspaceID:ctx.state.layout.selectedWorkspaceID,bootID:"boot",state:&state)
        XCTAssertEqual(binding.providerSessionID,sessionID);XCTAssertNil(binding.processID);XCTAssertEqual(binding.paneID,pane.id)
        XCTAssertEqual(state.sessions[0],original);XCTAssertEqual(state.layout.tabs[0],oldTab)
        XCTAssertEqual(state.layout.focusedPaneID,pane.id)
        XCTAssertNil(state.navigationRequest)
        let cmd=try ConversationResumeCoordinator.command(helper:"/tmp/Trano App/trano",pane:pane,launch:binding)
        XCTAssertLessThan(cmd.utf8.count,512);XCTAssertTrue(cmd.contains("'recovery' 'resume'"));XCTAssertFalse(cmd.contains(entry.cwd));XCTAssertFalse(cmd.contains(entry.title));XCTAssertFalse(cmd.contains("--last"))
    }
}
