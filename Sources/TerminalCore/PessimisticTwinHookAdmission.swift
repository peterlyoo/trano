import Foundation
import Darwin
import TranoSandboxBridge

struct TwinHookFileWitness: Equatable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let mode: UInt32
    let links: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}
struct TwinHookProcessWitness: Equatable {
    let birth: SupervisorProcessIdentity
    let executable: String
}
struct TwinHookAdmissionProbe {
    let userID: UInt32
    let process: (Int32) -> TwinHookProcessWitness?
    let file: (String) -> TwinHookFileWitness?
    let rootHook: (Int32, Int32, AgentKind) -> Bool
    let sandboxWrite: (Int32, String) -> TranoTwinSandboxWriteResult
}
public enum TwinHookAdmission {
    public static func validate(originPID: Int32, providerPID: Int32, provider: AgentKind, helperExecutable: String, protectedPath: String) throws {
        try validate(originPID: originPID, providerPID: providerPID, provider: provider, helperExecutable: helperExecutable,
            protectedPath: protectedPath, probe: TwinNativeHookAdmission.probe)
    }
    static func validate(originPID: Int32, providerPID: Int32, provider: AgentKind, helperExecutable: String, protectedPath: String, probe: TwinHookAdmissionProbe) throws {
        guard originPID > 1, providerPID > 1, originPID != providerPID, [.claude, .codex].contains(provider),
              validPath(helperExecutable), validPath(protectedPath), helperExecutable != protectedPath,
              let helper = probe.file(helperExecutable), helper.mode & UInt32(S_IFMT) == UInt32(S_IFREG),
              helper.owner == probe.userID || helper.owner == 0, helper.links == 1, helper.mode & 0o111 != 0, helper.mode & 0o022 == 0,
              let protected = probe.file(protectedPath), protected.path == protectedPath,
              protected.mode & UInt32(S_IFMT) == UInt32(S_IFREG), protected.owner == probe.userID,
              protected.links == 1, protected.mode & 0o077 == 0,
              let peer = probe.process(originPID), let parent = probe.process(providerPID),
              peer.birth.pid == originPID, parent.birth.pid == providerPID,
              peer.birth.ownerUID == probe.userID, parent.birth.ownerUID == probe.userID,
              peer.executable == helper.path, probe.rootHook(originPID, providerPID, provider) else {
            throw TerminalError.invalid("The twin hook is not the exact owned root helper")
        }
        let result = probe.sandboxWrite(originPID, protectedPath)
        guard result.result == 0, result.error == 0 else {
            throw TerminalError.invalid("A sandboxed tool or unverifiable process cannot submit trusted twin hooks")
        }
        guard probe.process(originPID) == peer, probe.process(providerPID) == parent,
              probe.file(helperExecutable) == helper, probe.file(protectedPath) == protected,
              probe.rootHook(originPID, providerPID, provider) else {
            throw TerminalError.invalid("Twin hook process or protected metadata changed during admission")
        }
    }
    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096 && !path.hasSuffix("/") && !path.contains("//")
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}

private enum TwinNativeHookAdmission {
    static var probe: TwinHookAdmissionProbe {
        TwinHookAdmissionProbe(userID: getuid(), process: process, file: file,
            rootHook: { ProcessIdentity.isRootHook(originPID: $0, providerPID: $1, provider: $2) },
            sandboxWrite: { pid, path in path.withCString { trano_twin_sandbox_check_write(pid, $0) } })
    }
    static func process(_ pid: Int32) -> TwinHookProcessWitness? {
        guard let birth = SupervisorProcessIdentity.read(pid) else { return nil }
        var bytes = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        guard count > 0, count < bytes.count, let path = String(validatingCString: bytes), path.hasPrefix("/"),
              SupervisorProcessIdentity.read(pid) == birth else { return nil }
        return TwinHookProcessWitness(birth: birth, executable: path)
    }
    static func file(_ path: String) -> TwinHookFileWitness? {
        guard let canonical = realpath(path, nil) else { return nil }
        defer { free(canonical) }
        let resolved = String(cString: canonical)
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat(), final = stat()
        guard fstat(descriptor, &info) == 0, lstat(path, &final) == 0, info.st_dev == final.st_dev, info.st_ino == final.st_ino else { return nil }
        return TwinHookFileWitness(path: resolved, device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), owner: info.st_uid,
            mode: UInt32(info.st_mode), links: UInt64(info.st_nlink), size: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}
