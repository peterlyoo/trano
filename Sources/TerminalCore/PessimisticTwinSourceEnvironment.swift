import Foundation
import Darwin

public enum TwinSourceEnvironment {
    public static func validate(source: TwinSourceBinding, read: (Int32) throws -> [UInt8] = nativeArguments,
                                identity: (Int32) -> SupervisorProcessIdentity? = SupervisorProcessIdentity.read) throws {
        guard identity(source.providerPID) == source.providerIdentity else { throw TerminalError.invalid("The original provider identity changed before authentication inspection") }
        var bytes = try read(source.providerPID)
        defer { bytes.withUnsafeMutableBytes { raw in if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) } } }
        guard identity(source.providerPID) == source.providerIdentity else { throw TerminalError.invalid("The original provider identity changed during authentication inspection") }
        guard try overrideKeys(in: bytes, provider: source.provider).isEmpty else {
            throw TerminalError.invalid("The original provider uses an authentication or endpoint override; register a managed profile before creating a twin")
        }
    }
    public static func overrideKeys(in bytes: [UInt8], provider: AgentKind) throws -> Set<String> {
        guard bytes.count >= 8, bytes.count <= 1_048_576, [.claude, .codex].contains(provider) else { throw TerminalError.invalid("The original provider environment is unavailable") }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard (1...16384).contains(argc) else { throw TerminalError.invalid("The original provider argument header is invalid") }
        var offset = MemoryLayout<Int32>.size
        func next() throws -> Range<Int> {
            let start = offset
            guard let end = bytes[offset...].firstIndex(of: 0) else { throw TerminalError.invalid("The original provider argument block is truncated") }
            offset = end + 1
            return start..<end
        }
        _ = try next()
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
        for _ in 0..<argc { guard offset < bytes.count else { throw TerminalError.invalid("The original provider arguments are truncated") }; _ = try next() }
        let keys: Set<String> = provider == .claude ? ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_HOST_AUTH_ENV_VAR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_CUSTOM_OAUTH_URL", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"] : ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_ORGANIZATION", "OPENAI_PROJECT_ID", "AZURE_OPENAI_API_KEY", "AZURE_OPENAI_ENDPOINT"]
        var result = Set<String>(), entries = 0
        while offset < bytes.count, bytes[offset] != 0 {
            let range = try next()
            entries += 1
            guard let separator = bytes[range].firstIndex(of: 61), separator > range.lowerBound else { throw TerminalError.invalid("The original provider environment entry is invalid") }
            if separator + 1 < range.upperBound, let name = String(bytes: bytes[range.lowerBound..<separator], encoding: .utf8), keys.contains(name) { result.insert(name) }
        }
        guard entries > 0, offset < bytes.count, bytes[offset] == 0 else { throw TerminalError.invalid("The original provider environment is unavailable or truncated") }
        return result
    }
    public static func nativeArguments(_ pid: Int32) throws -> [UInt8] {
        guard pid > 1 else { throw TerminalError.invalid("Invalid original provider process") }
        var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
        let size = 1_048_576
        var bytes = [UInt8](repeating: 0, count: size), actual = size
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &actual, nil, 0) }
        guard result == 0, actual > 0, actual < size else {
            bytes.withUnsafeMutableBytes { raw in if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) } }
            throw TerminalError.invalid("The original provider authentication environment changed during inspection")
        }
        if actual < size { bytes.removeSubrange(actual..<size) }
        return bytes
    }
}
