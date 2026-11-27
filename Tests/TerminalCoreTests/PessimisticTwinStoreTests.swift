import Foundation
import Darwin
import XCTest
@testable import TerminalCore
final class PessimisticTwinStoreTests:XCTestCase{
 // Implements: FR-TWIN-6, FR-TWIN-8, FR-TWIN-9
 func testSeparateSidecarRoundtripSurvivesOldPrimaryWriter()throws{
  let f=try TwinFixture();defer{f.remove()};let run=f.run();let store=TwinStore(root:f.root)
  try store.transaction{$0.runs.append(run)}
  XCTAssertEqual(try TwinStore(root:f.root).load().runs,[run])
  try Data("{}\n".utf8).write(to:f.root.appendingPathComponent("state.json"))
  XCTAssertEqual(try store.load().runs,[run])
 }
 func testUnownedSymbolicSidecarAndRootCannotBeRead()throws{
  let f=try TwinFixture();defer{f.remove()};let other=f.root.appendingPathComponent("other");try Data("{}".utf8).write(to:other)
  let file=f.root.appendingPathComponent("pessimistic-twins.json");try FileManager.default.createSymbolicLink(at:file,withDestinationURL:other)
  XCTAssertThrowsError(try TwinStore(root:f.root).load())
  try FileManager.default.removeItem(at:file);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:f.root.path)
  XCTAssertThrowsError(try TwinStore(root:f.root).load());try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:f.root.path)
 }
 func testMetadataAndOperationLeasesAreIndependentAndExclusive()throws{
  let f=try TwinFixture();defer{f.remove()};let first=TwinStore(root:f.root),other=TwinStore(root:f.root)
  var count=0
  let value=try first.withOperationLease{()->Int in
   XCTAssertNil(try other.withOperationLease{count+=1})
   try other.transaction{$0.runs.append(f.run())}
   return 7
  }
  XCTAssertEqual(value,7);XCTAssertEqual(count,0);XCTAssertEqual(try first.load().runs.count,1)
 }
 func testFinishedHistoryIsBoundedAndReservedIDsRemainProtectedAfterPrune()throws{
  let f=try TwinFixture();defer{f.remove()};let store=TwinStore(root:f.root)
  var ids:[String]=[]
  try store.transaction{state in
   for n in 0..<17{var r=f.run();r.phase = .finished;r.exitReason = .userInterrupt;r.updatedAt=Date(timeIntervalSince1970:Double(n));state.runs.append(r);ids.append(r.id)}
  }
  let result=try store.load()
  XCTAssertEqual(result.runs.count,16);XCTAssertFalse(result.runs.contains{$0.id==ids[0]})
  XCTAssertTrue(result.protectsDecision(TwinDecisionID.make(runID:ids[0],round:1)))
 }
 func testCorruptAndHardLinkedSidecarsAreRejectedWithoutRewritingThem()throws{
  let f=try TwinFixture();defer{f.remove()};let store=TwinStore(root:f.root),file=f.root.appendingPathComponent("pessimistic-twins.json")
  try Data("bad-json\n".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
  XCTAssertThrowsError(try store.load());XCTAssertEqual(try Data(contentsOf:file),Data("bad-json\n".utf8))
  try FileManager.default.removeItem(at:file);try store.transaction{$0.runs.append(f.run())}
  let linked=f.root.appendingPathComponent("hard-link");XCTAssertEqual(link(file.path,linked.path),0)
  XCTAssertThrowsError(try store.load())
 }

 func testFinishedRunCannotHideAnUncertainOperation()throws{
  let f=try TwinFixture();defer{f.remove()};let store=TwinStore(root:f.root)
  var run=f.run();run.rounds=[TwinRound(number:1,createdAt:f.date)];run.phase = .finished;run.exitReason = .userInterrupt;run.operation=TwinOperationIntent(kind:.snapshot,round:1,startedAt:f.date)
  XCTAssertThrowsError(try store.transaction{$0.runs.append(run)})
 }

}
