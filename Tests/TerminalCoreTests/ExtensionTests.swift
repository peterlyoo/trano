import XCTest
@testable import TerminalCore

final class ExtensionTests: XCTestCase {
    // Implements: FR-EXT-1, FR-EXT-2
    func testSharedSkillPreviewApplyAndSymlinkRejection() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-ext-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("---\nname: review\ndescription: Review changes\n---\nRead the patch.\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let skill = try runtime.importExtension(name: "review", kind: .skill, source: source)
        let claude = try runtime.addAccount(provider: .claude, label: "Claude")
        let codex = try runtime.addAccount(provider: .codex, label: "Codex")
        for account in [claude, codex] {
            let plan = try runtime.extensionPlan(accountID: account.id, extensionIDs: [skill.id])
            let directory = try runtime.accountRoot(account.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("skills/review").path))
            try runtime.applyExtensions(plan)
            let link = directory.appendingPathComponent("skills/review")
            XCTAssertEqual(try String(contentsOf: link.appendingPathComponent("SKILL.md"), encoding: .utf8), try String(contentsOf: source.appendingPathComponent("SKILL.md"), encoding: .utf8))
            XCTAssertEqual(try runtime.extensionPlan(accountID: account.id, extensionIDs: [skill.id]).files, plan.files)
        }
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertThrowsError(try runtime.importExtension(name: "bad", kind: .skill, source: source))
        XCTAssertEqual(try runtime.state().extensions.count, 1)
    }

    // Implements: FR-EXT-1, FR-EXT-2
    func testAdaptersPreviewConflictsAndExecutableSkills() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-ext-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("name: example\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let script = source.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\nprintf ok\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let skill = try runtime.importExtension(name: "example", kind: .skill, source: source)
        let spec = root.appendingPathComponent("mcp.json")
        try Data(#"{"mcpServers":{"example":{"type":"http","url":"https://example.com/mcp","httpHeaders":{"X-Example":"test"}}}}"#.utf8).write(to: spec)
        let mcp = try runtime.importExtension(name: "example-mcp", kind: .mcp, source: spec)
        let account = try runtime.addAccount(provider: .codex, label: "Codex")
        let directory = try runtime.accountRoot(account.id)
        let plan = try runtime.extensionPlan(accountID: account.id, extensionIDs: [skill.id, mcp.id])
        XCTAssertTrue(plan.files["trano.config.toml"]!.contains("http_headers"))
        XCTAssertFalse(plan.files["trano.config.toml"]!.contains("httpHeaders"))
        try runtime.applyExtensions(plan)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("skills/example/run.sh").path))
        try runtime.applyExtensions(try runtime.extensionPlan(accountID: account.id, extensionIDs: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("skills/example").path))
        let config = directory.appendingPathComponent("trano.config.toml")
        let edited = "# User edited\n" + (try String(contentsOf: config, encoding: .utf8))
        try Data(edited.utf8).write(to: config)
        XCTAssertThrowsError(try runtime.applyExtensions(plan))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), edited)
    }

    // Implements: FR-EXT-2
    func testCorruptReceiptCannotEscapeOwnedProfile() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-ext-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try runtime.addAccount(provider: .claude, label: "Claude")
        let directory = try runtime.accountRoot(account.id)
        let receipt = directory.appendingPathComponent(".trano-extensions.json")
        try Data(#"{"extensionIDs":[],"files":{"../../outside":"abc"},"links":{}}"#.utf8).write(to: receipt)
        XCTAssertThrowsError(try runtime.applyExtensions(runtime.extensionPlan(accountID: account.id, extensionIDs: [])))
    }

    // Implements: FR-EXT-2
    func testPluginPlansUseProviderCLIAndIsolatedEnvironment() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-plugin-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = root.appendingPathComponent("plugin.json")
        try Data(#"{"claude":"review@tools","codex":"review@tools"}"#.utf8).write(to: spec)
        let plugin = try runtime.importExtension(name: "review", kind: .plugin, source: spec)
        for provider in [AgentKind.claude, .codex] {
            let account = try runtime.addAccount(provider: provider, label: provider.rawValue)
            let command = try runtime.pluginCommand(accountID: account.id, extensionID: plugin.id)
            XCTAssertEqual(command.arguments, provider == .claude ? ["claude", "plugin", "install", "--scope", "user", "review@tools"] : ["codex", "plugin", "add", "review@tools"])
            XCTAssertEqual(command.environment[provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"], try runtime.accountRoot(account.id).path)
        }
    }
}
