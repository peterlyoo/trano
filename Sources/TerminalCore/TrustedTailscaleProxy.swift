import Foundation
#if canImport(Darwin)
import Darwin
import Security
#endif

public struct TrustedTailscaleProxy { init() {} }

struct TailscaleProxyPeerFacts {
    let uid: UInt32
    let ownerUID: UInt32
    let pid: Int32
    let executableName: String
    let validTailscaleSignature: Bool
    let rootOwnedUnwritableExecutable: Bool
}

enum TailscaleProxyPeerPolicy {
    static func allows(_ facts: TailscaleProxyPeerFacts) -> Bool {
        guard facts.pid > 1, facts.uid == 0 || facts.uid == facts.ownerUID else { return false }
        if facts.uid == 0, facts.executableName == "tailscaled", facts.rootOwnedUnwritableExecutable { return true }
        return ["IPNExtension", "io.tailscale.ipn.macsys.network-extension", "io.tailscale.ipn.macos.network-extension"].contains(facts.executableName) && facts.validTailscaleSignature
    }

    static func inspect(socket: Int32) -> TrustedTailscaleProxy? {
        #if canImport(Darwin)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0, let pid = UnixSocket.peerPID(socket), pid > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        let path = String(cString: bytes), name = URL(fileURLWithPath: path).lastPathComponent
        var info = stat()
        let rootOwned = lstat(path, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o022 == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        var code: SecCode?, requirement: SecRequirement?
        var signature = false
        if SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
           let code,
           SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"W5364U7YZB\"" as CFString, [], &requirement) == errSecSuccess {
            signature = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        }
        let facts = TailscaleProxyPeerFacts(uid: uid, ownerUID: getuid(), pid: pid, executableName: name, validTailscaleSignature: signature, rootOwnedUnwritableExecutable: rootOwned)
        return allows(facts) ? TrustedTailscaleProxy() : nil
        #else
        return nil
        #endif
    }
}
