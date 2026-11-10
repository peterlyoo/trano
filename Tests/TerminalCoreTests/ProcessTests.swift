import XCTest
import Darwin
@testable import TerminalCore

final class ProcessTests: XCTestCase {
    // Implements: NFR-CORE-2, FR-INPUT-1
    func testExactArgumentsAndExplicitEnvironmentRejectEmbeddedNUL() throws {
        let text = "한글 ".decomposedStringWithCanonicalMapping + "' ; $() 👩🏽‍💻"
        let result = try CommandRunner.run("/usr/bin/printf", ["%s", text], environment: ["TRANO_FIXTURE": "격리"])
        XCTAssertEqual(result.stdout, Data(text.utf8))
        XCTAssertThrowsError(try CommandRunner.run("/usr/bin/printf", ["%s", "before\0after"]))
        XCTAssertThrowsError(try CommandRunner.run("/usr/bin/true", [], environment: ["NAME": "before\0after"]))
        XCTAssertThrowsError(try CommandRunner.run("/usr/bin/true", [], environment: ["BAD=NAME": "value"]))
    }

    // Implements: NFR-CORE-2
    func testLargeDuplexTransferAndExitStatuses() throws {
        let input = Data(repeating: 0xD1, count: 1_048_576)
        let result = try CommandRunner.run("/bin/sh", ["-c", "head -c 524288 /dev/zero >&2 & cat; wait"], input: input, limit: 2_097_152)
        XCTAssertEqual(result.stdout, input)
        XCTAssertEqual(result.stderr.count, 524288)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try CommandRunner.run("/bin/sh", ["-c", "exit 23"]).status, 23)
        XCTAssertEqual(try CommandRunner.run("/bin/sh", ["-c", "kill -TERM $$"]).status, SIGTERM)
    }

    // Implements: NFR-CORE-2
    func testTimeoutReapsChildAndDoesNotInheritUnrelatedDescriptor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trano-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        XCTAssertThrowsError(try CommandRunner.run("/bin/sh", ["-c", "echo $$ > '" + pidFile.path + "'; exec sleep 5"], timeout: 0.2))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        let fd = open(directory.appendingPathComponent("private-fixture").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let highFD = fcntl(fd, F_DUPFD, 80)
        XCTAssertGreaterThanOrEqual(highFD, 80)
        defer { close(highFD) }
        let output = try CommandRunner.run("/bin/sh", ["-c", "if [ -e /dev/fd/\(highFD) ]; then printf inherited; else printf closed; fi"])
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "closed")
    }
    // Implements: NFR-CORE-2
    func testOutputIsBoundedAndInheritedPipeDoesNotDelayCompletion() throws {
        XCTAssertThrowsError(try CommandRunner.run("/usr/bin/yes", [], limit: 4096))
        let start = Date()
        let result = try CommandRunner.run("/bin/sh", ["-c", "sleep 2 & printf ready"], timeout: 1)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ready")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertThrowsError(try CommandRunner.run("/bin/sleep", ["2"], timeout: 0.1))
    }

    // Implements: FR-REMOTE-3, NFR-CORE-2
    func testStdinAndStderrRemainSeparateWithoutBrokenPipeCrash() throws {
        let result = try CommandRunner.run("/bin/sh", ["-c", "printf banner >&2; cat"], input: Data("한글".utf8))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "한글")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "banner")
        _ = try? CommandRunner.run("/usr/bin/false", [], input: Data(repeating: 65, count: 1_048_576))
    }
}
