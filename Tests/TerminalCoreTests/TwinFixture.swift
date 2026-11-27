import Foundation
import Darwin
@testable import TerminalCore
struct TwinFixture {
 let root:URL
 let source:TwinSourceBinding
 let date=Date(timeIntervalSince1970:100)
 init()throws{
  root=URL(fileURLWithPath:"/tmp").appendingPathComponent("trano-twin-unit-"+UUID().uuidString.prefix(8));try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  source=TwinSourceBinding(paneID:UUID().uuidString.lowercased(),generation:UUID().uuidString.lowercased(),conversationID:UUID().uuidString.lowercased(),cwd:"/source",configurationRoot:"/profile",provider:.codex,backendPID:123,providerPID:124,backendIdentity:.init(pid:123,ownerUID:getuid(),startedAtSeconds:10,startedAtMicroseconds:0),providerIdentity:.init(pid:124,ownerUID:getuid(),startedAtSeconds:11,startedAtMicroseconds:0))
 }
 func remove(){try? FileManager.default.removeItem(at:root)}
 func run()->TwinRun{TwinRun(source:source,mode:.codeReview,createdAt:date,enabledCompletionID:"before")}
 func completion(_ id:String="after",time:TimeInterval=101,revision:UInt64=1)->TwinCompletion{.init(id:id,turnID:"turn-"+id,completedAt:Date(timeIntervalSince1970:time),inputRevision:revision)}
 func snapshot(run:TwinRun,round:Int=1)->TwinGitSnapshot{
  let node=WorktreeFileIdentity(device:1,inode:2);let path="/twins/"+run.id+"/\(round)";let common="/source/.git"
  return .init(runID:run.id,round:round,repositoryRoot:"/source",sourceCWD:"/source",sourceGitDirectory:common,commonDirectory:common,sourceBranch:"refs/heads/main",sourceHEAD:String(repeating:"a",count:40),sourceIndexSHA256:String(repeating:"b",count:64),sourceTree:String(repeating:"c",count:40),snapshotCommit:String(repeating:"d",count:40),twinBranch:"refs/heads/trano/twin/"+run.id+"/\(round)",worktreePath:path,ownership:.init(path:path,commonDirectory:common,adminDirectory:common+"/worktrees/"+run.id,pathIdentity:node,gitFileIdentity:node,adminIdentity:node,commonIdentity:node))
 }
 func pane(conversationID:String?=nil)->TwinPaneBinding{.init(paneID:UUID().uuidString.lowercased(),generation:UUID().uuidString.lowercased(),backendPID:200,backendIdentity:.init(pid:200,ownerUID:getuid(),startedAtSeconds:20,startedAtMicroseconds:0),conversationID:conversationID)}
}
