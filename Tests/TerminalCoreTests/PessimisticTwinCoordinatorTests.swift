import Foundation
import Darwin
import XCTest
@testable import TerminalCore
final class PessimisticTwinCoordinatorTests:XCTestCase{
 // Implements: FR-TWIN-1, FR-TWIN-2, FR-TWIN-3, FR-TWIN-5, FR-TWIN-6, FR-TWIN-7, FR-TWIN-8, FR-TWIN-9
 func testCompleteApprovedMergeFlowRequiresNewDoneAndQueuesOnlyOnce()throws{
  let f=try TwinFixture();defer{f.remove()};let store=TwinStore(root:f.root),backend=FakeTwinBackend(f);let c=TwinCoordinator(store:store,backend:backend)
  let run=try c.enable(source:f.source,mode:.codeReview,enabledCompletionID:"before",now:f.date)
  try c.processPending(now:Date(timeIntervalSince1970:101));XCTAssertEqual(backend.snapshots,0)
  backend.context=TwinRuntimeContext(source:f.source,completion:f.completion(),inputClear:true)
  let ready=try drive(c,store:store,id:run.id,to:.reviewing,now:102)
  XCTAssertEqual(backend.snapshots,1);XCTAssertEqual(backend.launches,1);XCTAssertNotNil(ready.latestRound?.pane)
  let pane=try XCTUnwrap(ready.latestRound?.pane);let report=TwinReport(status:"working",rationale:"Fixed reproducible bug",changedFiles:["file.swift"])
  try c.submitReport(runID:run.id,round:1,pane:pane,report:report,now:Date(timeIntervalSince1970:103));backend.reviewDone=true
  let decision=try drive(c,store:store,id:run.id,to:.awaitingDecision,now:104)
  XCTAssertEqual(backend.cards,1);XCTAssertTrue(backend.sawProtectedCard)
  let consent=TwinConsent(choice:.merge,decisionID:try XCTUnwrap(decision.latestRound?.decisionID),twinTip:try XCTUnwrap(decision.latestRound?.tip),sourceCompletionID:"after",chosenAt:Date(timeIntervalSince1970:105))
  try c.recordNativeConsent(runID:run.id,round:1,consent:consent,now:Date(timeIntervalSince1970:105))
  try c.processPending(now:Date(timeIntervalSince1970:106));XCTAssertEqual(backend.merges,0)
  backend.context=TwinRuntimeContext(source:f.source,completion:f.completion("next",time:107),inputClear:true,hasQueuedInput:true)
  try c.processPending(now:Date(timeIntervalSince1970:108));XCTAssertEqual(backend.merges,0)
  backend.context=TwinRuntimeContext(source:f.source,completion:f.completion("next",time:107),inputClear:true)
  _=try drive(c,store:store,id:run.id,to:.awaitingSourceResponse,now:109)
  XCTAssertEqual(backend.merges,1);XCTAssertEqual(backend.forwards,1)
  try c.processPending(now:Date(timeIntervalSince1970:110));XCTAssertEqual(backend.forwards,1)
  try c.submitSourceResponse(runID:run.id,round:1,source:f.source,report:.init(status:"no_further_improvement",rationale:"Accepted the fix",changedFiles:[]),now:Date(timeIntervalSince1970:111))
  try c.processPending(now:Date(timeIntervalSince1970:112));XCTAssertEqual(backend.cleanups,0)
  backend.context=TwinRuntimeContext(source:f.source,completion:f.completion("response",time:113),inputClear:true)
  let finished=try drive(c,store:store,id:run.id,to:.finished,now:114)
  XCTAssertEqual(finished.exitReason,.agentAgreement);XCTAssertEqual(backend.cleanups,1);XCTAssertTrue(try store.load().reservedWorktrees.isEmpty)
 }
 func testInFlightRestartDoesNotRepeatMutations()throws{
  let f=try TwinFixture();defer{f.remove()};let s=TwinStore(root:f.root),b=FakeTwinBackend(f),c=TwinCoordinator(store:s,backend:b)
  let run=try c.enable(source:f.source,mode:.generalReview,now:f.date)
  try s.transaction{state in let i=state.runs.firstIndex{$0.id==run.id}!;state.runs[i].rounds=[TwinRound(number:1,createdAt:f.date)];state.runs[i].phase = .launching;state.runs[i].operation=TwinOperationIntent(kind:.launch,round:1,startedAt:f.date)}
  try c.processPending(now:Date(timeIntervalSince1970:101))
  XCTAssertEqual(try s.load().runs[0].phase,.needsReview);XCTAssertEqual(b.launches,0)
 }
 func testStopCleansOwnedResourcesAndUsesExactExitReason()throws{
  let f=try TwinFixture();defer{f.remove()};let s=TwinStore(root:f.root),b=FakeTwinBackend(f),c=TwinCoordinator(store:s,backend:b)
  let run=try c.enable(source:f.source,mode:.securityReview,now:f.date)
  try c.stop(id:run.id,now:Date(timeIntervalSince1970:101))
  let done=try drive(c,store:s,id:run.id,to:.finished,now:102)
  XCTAssertEqual(done.exitReason,.userInterrupt);XCTAssertEqual(b.launches,0)
 }
 func testStopWaitsForOwnedProviderExitWithoutTreatingPreMutationWaitAsAnInterruptedDelete()throws {
  let f=try TwinFixture();defer{f.remove()};let store=TwinStore(root:f.root),backend=FakeTwinBackend(f),coordinator=TwinCoordinator(store:store,backend:backend)
  let run=try coordinator.enable(source:f.source,mode:.codeReview,now:f.date)
  backend.context = .init(source:f.source,completion:f.completion(),inputClear:true)
  _=try drive(coordinator,store:store,id:run.id,to:.reviewing,now:102)
  try coordinator.stop(id:run.id,now:Date(timeIntervalSince1970:103))
  backend.pendingCleanup=true
  try coordinator.processPending(now:Date(timeIntervalSince1970:104))
  let held=try XCTUnwrap(store.load().runs.first{$0.id==run.id})
  XCTAssertEqual(held.phase,.cleaning);XCTAssertNil(held.operation);XCTAssertEqual(backend.cleanups,0)
  backend.pendingCleanup=false
  let finished=try drive(coordinator,store:store,id:run.id,to:.finished,now:105)
  XCTAssertEqual(finished.exitReason,.userInterrupt);XCTAssertEqual(backend.cleanups,1)
 }
 private func drive(_ c:TwinCoordinator,store:TwinStore,id:String,to phase:TwinPhase,now:TimeInterval)throws->TwinRun{
  for _ in 0..<12{let run=try XCTUnwrap(store.load().runs.first{$0.id==id});if run.phase==phase{return run};_ = try c.processPending(now:Date(timeIntervalSince1970:now))}
  let run=try XCTUnwrap(store.load().runs.first{$0.id==id});XCTAssertEqual(run.phase,phase);return run
 }
}
final class FakeTwinBackend:TwinBackend{
 let f:TwinFixture
 var context:TwinRuntimeContext
 var snapshots=0,launches=0,cards=0,merges=0,forwards=0,cleanups=0
 var reviewDone=false,sawProtectedCard=false,cleanReview=true,repeatSourceConversation=false,mismatchFiles=false
 var reviewTime:TimeInterval=104
 var pendingCleanup = false
 var failKind:TwinOperationKind?
 var mergeResult=TwinMergeOutcome.merged(commit:String(repeating:"f",count:40))
 var onOperation:(()->Void)?
 init(_ f:TwinFixture){self.f=f;context = .init(source:f.source,completion:f.completion("before",time:99),inputClear:true)}
 func sourceContext(run:TwinRun)throws->TwinRuntimeContext{context}
 func snapshot(run:TwinRun,round:TwinRound)throws->TwinGitSnapshot{snapshots+=1;onOperation?();if failKind == .snapshot{throw TerminalError.runtime("fixture snapshot stopped")};return f.snapshot(run:run,round:round.number)}
 func launch(run:TwinRun,round:TwinRound)throws->TwinPaneBinding{launches+=1;onOperation?();if failKind == .launch{throw TerminalError.runtime("fixture launch stopped")};return f.pane()}
 func completedReview(run:TwinRun,round:TwinRound)throws->TwinReviewOutcome?{
  guard reviewDone,let report=round.report,var pane=round.pane else{return nil};pane.conversationID=repeatSourceConversation ? run.source.conversationID:UUID().uuidString.lowercased()
  return .init(pane:pane,completion:f.completion("review",time:reviewTime),report:report,tip:String(repeating:"e",count:40),changedFiles:mismatchFiles ? ["wrong.swift"]:report.changedFiles,clean:cleanReview)
 }
 func publishDecision(run:TwinRun,round:TwinRound,decisionID:String)throws{onOperation?();cards+=1;sawProtectedCard=(try TwinStore(root:f.root).load()).decisionBinding(id:decisionID)?.runID == run.id}
 func merge(run:TwinRun,round:TwinRound,sourceContext:TwinRuntimeContext)throws->TwinMergeOutcome{onOperation?();merges+=1;return mergeResult}
 func enqueueFeedback(run:TwinRun,round:TwinRound,idempotencyKey:String)throws->String{onOperation?();forwards+=1;return "queue-"+idempotencyKey}
 func cleanup(run:TwinRun,round:TwinRound)throws{if pendingCleanup { throw TwinCleanupPending(operationID: run.operation!.id, message: "Waiting for owned provider exit") };cleanups+=1;onOperation?();if failKind == .cleanup{throw TerminalError.runtime("fixture cleanup held")}}
}
