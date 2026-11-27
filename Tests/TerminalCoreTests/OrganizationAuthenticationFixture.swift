import Foundation
@testable import TerminalCore

final class OrganizationAuthenticationIdentityFixture {
    var keychainRevision = 0
    var keychainQueries = 0
    var executableQueries = 0
    var denyKeychain = false
    var denyExecutable = false

    func reader() -> ClaudeAuthenticationIdentityReader {
        ClaudeAuthenticationIdentityReader(environment: { ["USER": "fixture", "PATH": "/fixture/bin"] },
            keychain: { _, _ in
                self.keychainQueries += 1
                if self.denyKeychain { throw TerminalError.invalid("Synthetic metadata unavailable") }
                return ClaudeKeychainMetadata(exists: true, digest: AccountSessionFiles.digest(Data("metadata-\(self.keychainRevision)".utf8)))
            }, executable: { _, allowProbe in
                if allowProbe { self.executableQueries += 1 }
                if self.denyExecutable { throw TerminalError.invalid("Synthetic unsupported storage") }
                return AccountSessionFiles.digest(Data("synthetic-supported-executable".utf8))
            }, contextReader: { context, _ in
                AccountSessionFiles.digest(Data(("synthetic-context:" + context.cwd).utf8))
            })
    }
}

func organizationFixtureRuntime(root: URL) throws -> TerminalRuntime {
    let runtime = try TerminalRuntime(root: root)
    runtime.accountAuthenticationIdentityReader = OrganizationAuthenticationIdentityFixture().reader()
    return runtime
}
