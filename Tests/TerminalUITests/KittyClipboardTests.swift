import AppKit
import SwiftTerm
import XCTest
import TerminalCore
import UniformTypeIdentifiers
@testable import TranoApp

@MainActor private final class KittyReplyRecorder: TerminalViewDelegate {
    let bridge: TerminalBridge
    var reply = Data()
    init(bridge: TerminalBridge) { self.bridge = bridge }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { reply.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        bridge.kittyClipboardCapabilities(source: source)
    }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? {
        bridge.kittyClipboardAvailableMimeTypes(source: source, location: location)
    }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? {
        bridge.kittyClipboardRead(source: source, location: location, mimeType: mimeType)
    }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult {
        bridge.kittyClipboardWrite(source: source, location: location, content: content)
    }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult {
        bridge.kittyClipboardRequestPermission(source: source, request: request)
    }
}

@MainActor private final class KittyPermissionLog {
    var requests: [KittyClipboardPermissionRequest] = []
    var result: KittyClipboardPermissionResult = .allow(rememberPassword: false)
}

private final class KittyGateCoreDelegate: TerminalDelegate {
    var onSend: ((Terminal, ArraySlice<UInt8>) -> Void)?
    func send(source: Terminal, data: ArraySlice<UInt8>) { onSend?(source, data) }
    func kittyClipboardCapabilities(source: Terminal) -> KittyClipboardCapabilities { .standard }
}

final class KittyClipboardTests: XCTestCase {
    // Implements: FR-KITTY-1, FR-KITTY-3
    @MainActor func testConfiguredTerminalAdvertisesCompleteStandardClipboardServices() throws {
        _ = NSApplication.shared
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 300), options: TerminalOptions(kittyClipboardPolicy: .all))
        view.configure(TerminalSettings())
        let bridge = try XCTUnwrap(view.terminalDelegate as? TerminalBridge)
        XCTAssertEqual(bridge.kittyClipboardCapabilities(source: view), .standard)
        XCTAssertFalse(bridge.kittyClipboardCapabilities(source: view).contains(.primaryRead))
        XCTAssertFalse(bridge.kittyClipboardCapabilities(source: view).contains(.primaryWrite))
    }

    // Implements: FR-KITTY-3
    @MainActor func testNativeFeedAndSendReportsModeSupportAndEnableReset() async throws {
        _ = NSApplication.shared
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 300), options: TerminalOptions(kittyClipboardPolicy: .all))
        view.configure(TerminalSettings())
        let recorder = KittyReplyRecorder(bridge: try XCTUnwrap(view.terminalDelegate as? TerminalBridge))
        view.terminalDelegate = recorder
        for (prefix, expected) in [("", "2"), ("\u{1b}[?5522h", "1"), ("\u{1b}[?5522l", "2")] {
            recorder.reply.removeAll()
            view.feed(text: prefix + "\u{1b}[?5522$p")
            try await settle { !recorder.reply.isEmpty }
            XCTAssertEqual(String(decoding: recorder.reply, as: UTF8.self), "\u{1b}[?5522;" + expected + "$y")
        }
    }

    // Implements: FR-KITTY-1, FR-KITTY-2
    @MainActor func testListsPrivatePasteboardTypesWithoutReadPermissionAndEchoesSanitizedID() async throws {
        let f = try fixture(permission: .deny)
        defer { f.board.releaseGlobally() }
        try seed(f, text: "한글 sample", image: Data([137, 80, 78, 71]))
        f.view.feed(text: osc("type=read:id=r!1?", payload: b64(".")))
        try await settle { self.packets(f).count == 3 }
        let result = packets(f)
        XCTAssertTrue(result.allSatisfy { $0.contains("id=r1") })
        let list = try XCTUnwrap(payloads(".", in: result).first)
        let names = Set(String(decoding: list, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init))
        XCTAssertTrue(Set(["text/plain", "image/png"]).isSubset(of: names))
        XCTAssertTrue(f.permissions.requests.isEmpty)
    }

    // Implements: FR-KITTY-1, FR-KITTY-2
    @MainActor func testPermissionedUnicodeAndImageReadsUseExactBytesAndChunkLimits() async throws {
        let f = try fixture()
        defer { f.board.releaseGlobally() }
        let text = "한글 e\u{301} 👩🏽‍💻\n" + String(repeating: "abcdef", count: 2000)
        let image = Data([137, 80, 78, 71, 0, 255, 128, 10])
        try seed(f, text: text, image: image)
        f.view.feed(text: osc("type=read:id=chunks", payload: b64("text/plain image/png")))
        try await settle { self.packets(f).last?.contains("status=DONE") == true }
        let result = packets(f)
        let chunks = payloads("text/plain", in: result)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 4096 })
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, Data(text.utf8))
        XCTAssertEqual(payloads("image/png", in: result), [image])
        XCTAssertEqual(f.permissions.requests.count, 1)
        XCTAssertEqual(f.permissions.requests.first?.direction, .read)
    }

    // Implements: FR-KITTY-1, FR-KITTY-2
    @MainActor func testDeniedAndUnsupportedPrimaryReadsNeverReturnData() async throws {
        let f = try fixture(permission: .deny)
        defer { f.board.releaseGlobally() }
        try seed(f, text: "private clipboard", image: nil)
        f.view.feed(text: osc("type=read", payload: b64("text/plain")))
        try await settle { !self.packets(f).isEmpty }
        XCTAssertEqual(packets(f), ["type=read:status=EPERM"])
        XCTAssertEqual(f.permissions.requests.count, 1)
        f.recorder.reply.removeAll()
        f.view.feed(text: osc("type=read:loc=primary", payload: b64(".")))
        try await settle { !self.packets(f).isEmpty }
        XCTAssertEqual(packets(f), ["type=read:status=ENOSYS"])
        XCTAssertEqual(f.permissions.requests.count, 1)
    }

    // Implements: FR-KITTY-1
    @MainActor func testWritesMultipleMIMEsAndAliasesOnlyAfterFinalPacket() async throws {
        let f = try fixture()
        defer { f.board.releaseGlobally() }
        try seed(f, text: "keep until commit", image: nil)
        let text = Data("새 문자열 e\u{301} 👩🏽‍💻".utf8)
        let encoded = text.base64EncodedString()
        let pivot = encoded.index(encoded.startIndex, offsetBy: 5)
        let image = Data([137, 80, 78, 71, 255, 0])
        f.view.feed(text: osc("type=write:id=write1") +
            osc("type=wdata:mime=" + b64("text/plain"), payload: String(encoded[..<pivot])) +
            osc("type=wdata:mime=" + b64("text/plain"), payload: String(encoded[pivot...])) +
            osc("type=wdata:mime=" + b64("image/png"), payload: image.base64EncodedString()) +
            osc("type=walias:mime=" + b64("text/plain"), payload: b64("text/x-trano")))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(f.board.string(forType: .string), "keep until commit")
        f.view.feed(text: osc("type=wdata"))
        try await settle { self.packets(f).contains { $0.contains("status=DONE") } }
        XCTAssertEqual(packets(f), ["type=write:status=DONE:id=write1"])
        XCTAssertEqual(f.host.read(location: .standard, mimeType: "text/plain"), .data(text))
        XCTAssertEqual(f.host.read(location: .standard, mimeType: "image/png"), .data(image))
        XCTAssertEqual(f.host.read(location: .standard, mimeType: "text/x-trano"), .data(text))
        XCTAssertEqual(f.board.pasteboardItems?.count, 1)
        XCTAssertEqual(f.permissions.requests.filter { $0.direction == .write }.count, 1)
    }

    // Implements: FR-KITTY-1
    @MainActor func testNativeCanonicalizationDoesNotLoseAnExplicitMIMEAlias() throws {
        let candidates = ["image/jpg", "image/x-png", "image/x-tiff", "text/xml", "application/x-json", "text/x-json", "text/javascript", "application/javascript"]
        let mapping = try XCTUnwrap(candidates.compactMap { alias -> (alias: String, canonical: String)? in
            guard let type = UTType(mimeType: alias), let canonical = type.preferredMIMEType,
                  canonical.caseInsensitiveCompare(alias) != .orderedSame,
                  UTType(mimeType: canonical)?.identifier == type.identifier else { return nil }
            return (alias, canonical)
        }.first, "Expected a platform MIME alias for this native mapping regression")
        let f = try fixture()
        defer { f.board.releaseGlobally() }
        let payload = Data([0, 1, 127, 128, 255])
        let content = KittyClipboardWriteContent(representations: [KittyClipboardRepresentation(mimeType: mapping.canonical, data: payload)], aliases: [KittyClipboardAlias(name: mapping.alias, target: mapping.canonical)])
        XCTAssertEqual(f.host.write(location: .standard, content: content), .success)
        XCTAssertTrue(try XCTUnwrap(f.host.mimeTypes(location: .standard)).contains(mapping.alias))
        XCTAssertEqual(f.host.read(location: .standard, mimeType: mapping.alias), .data(payload))
        XCTAssertEqual(f.host.read(location: .standard, mimeType: mapping.canonical), .data(payload))
    }

    // Implements: FR-KITTY-1
    @MainActor func testNonCanonicalRepresentationKeepsItsNativeTypeAndVerbatimMIME() throws {
        let f = try fixture()
        defer { f.board.releaseGlobally() }
        let native = try XCTUnwrap(UTType(mimeType: "image/jpg"))
        XCTAssertEqual(native.preferredMIMEType, "image/jpeg")
        let bytes = Data([0, 1, 127, 128, 255])
        XCTAssertEqual(f.host.write(location: .standard, content: KittyClipboardWriteContent(representations: [KittyClipboardRepresentation(mimeType: "image/jpg", data: bytes)])), .success)
        XCTAssertEqual(f.board.data(forType: NSPasteboard.PasteboardType(native.identifier)), bytes)
        XCTAssertTrue(try XCTUnwrap(f.host.mimeTypes(location: .standard)).contains("image/jpg"))
        XCTAssertEqual(f.host.read(location: .standard, mimeType: "image/jpg"), .data(bytes))
        XCTAssertEqual(f.host.read(location: .standard, mimeType: "image/jpeg"), .data(bytes))
    }

    // Implements: FR-KITTY-1
    @MainActor func testMIMEAliasCanBeReadByAReplacementHostWithoutAnInMemoryAliasCache() throws {
        let f = try fixture()
        defer { f.board.releaseGlobally() }
        let bytes = Data([0, 1, 127, 128, 255])
        let content = KittyClipboardWriteContent(representations: [KittyClipboardRepresentation(mimeType: "image/jpeg", data: bytes)], aliases: [KittyClipboardAlias(name: "image/jpg", target: "image/jpeg")])
        XCTAssertEqual(f.host.write(location: .standard, content: content), .success)
        let replacementView = TranoView.makeClipboardTerminal(frame: .zero)
        let replacement = KittyClipboardHost(view: replacementView, pasteboard: f.board, availability: { true })
        XCTAssertTrue(try XCTUnwrap(replacement.mimeTypes(location: .standard)).contains("image/jpg"))
        XCTAssertEqual(replacement.read(location: .standard, mimeType: "image/jpg"), .data(bytes))
    }

    // Implements: FR-KITTY-1
    @MainActor func testInvalidWriteDiscardsTheTransactionAndNewWriteCanRecover() async throws {
        let f = try fixture()
        defer { f.board.releaseGlobally() }
        try seed(f, text: "preserved", image: nil)
        f.view.feed(text: osc("type=write") + osc("type=wdata:mime=" + b64("text/plain"), payload: "%%%"))
        try await settle { !self.packets(f).isEmpty }
        XCTAssertEqual(packets(f), ["type=write:status=EINVAL"])
        f.view.feed(text: osc("type=wdata:mime=" + b64("text/plain"), payload: b64("discarded")) + osc("type=wdata"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.board.string(forType: .string), "preserved")
        f.recorder.reply.removeAll()
        f.view.feed(text: osc("type=write") + osc("type=wdata:mime=" + b64("text/plain"), payload: b64("recovered")) + osc("type=wdata"))
        try await settle { !self.packets(f).isEmpty }
        XCTAssertEqual(packets(f), ["type=write:status=DONE"])
        XCTAssertEqual(f.board.string(forType: .string), "recovered")
    }

    // Implements: FR-KITTY-1, FR-KITTY-2
    @MainActor func testReadPasswordGrantIsBoundToThisTerminalAndResetRevokesIt() async throws {
        let f = try fixture(permission: .allow(rememberPassword: true))
        defer { f.board.releaseGlobally() }
        try seed(f, text: "authorized", image: nil)
        let request = osc("type=read:pw=" + b64("fixture-session-token") + ":name=" + b64("Fixture Editor"), payload: b64("text/plain"))
        for _ in 0..<2 {
            f.recorder.reply.removeAll()
            f.view.feed(text: request)
            try await settle { self.packets(f).last?.contains("status=DONE") == true }
        }
        XCTAssertEqual(f.permissions.requests.count, 1)
        XCTAssertTrue(f.permissions.requests[0].canRememberPassword)
        f.recorder.reply.removeAll()
        f.view.feed(text: "\u{1b}c" + request)
        try await settle { self.packets(f).last?.contains("status=DONE") == true }
        XCTAssertEqual(f.permissions.requests.count, 2)
    }

    // Implements: FR-KITTY-2, FR-KITTY-3
    @MainActor func testImageOnlyPasteUsesTheNativeEventAndOneTimePermissionToken() async throws {
        let f = try fixture(permission: .deny)
        defer { f.board.releaseGlobally() }
        let image = Data([137, 80, 78, 71, 0, 255])
        try seed(f, text: nil, image: image)
        f.view.feed(text: "\u{1b}[?5522h\u{1b}[?5522$p")
        try await settle { String(decoding: f.recorder.reply, as: UTF8.self).contains("5522;1$y") }
        f.recorder.reply.removeAll()
        XCTAssertTrue(f.view.tryNativeKittyPaste(NSNull()))
        try await settle { self.packets(f).count == 3 }
        let event = packets(f)
        let first = try XCTUnwrap(event.first)
        let tokenField = try XCTUnwrap(first.split(separator: ":").first { $0.hasPrefix("pw=") })
        let token = String(tokenField.dropFirst(3))
        XCTAssertFalse(token.isEmpty)
        XCTAssertTrue(f.permissions.requests.isEmpty)
        let list = try XCTUnwrap(payloads(".", in: event).first)
        XCTAssertTrue(String(decoding: list, as: UTF8.self).split(whereSeparator: \.isWhitespace).contains("image/png"))
        XCTAssertFalse(f.recorder.reply.range(of: image) != nil)
        let read = osc("type=read:pw=" + token + ":name=" + b64("Paste event"), payload: b64("image/png"))
        f.recorder.reply.removeAll()
        f.view.feed(text: read)
        try await settle { self.packets(f).last?.contains("status=DONE") == true }
        XCTAssertEqual(payloads("image/png", in: packets(f)), [image])
        XCTAssertTrue(f.permissions.requests.isEmpty)
        f.recorder.reply.removeAll()
        f.view.feed(text: read)
        try await settle { !self.packets(f).isEmpty }
        XCTAssertEqual(packets(f), ["type=read:status=EPERM"])
        XCTAssertEqual(f.permissions.requests.count, 1)
    }

    // Implements: FR-KITTY-2, FR-KITTY-3
    @MainActor func testNativePasteGateSuppressesTextFallbackAndNeverCapturesAnotherOwnerOrThread() throws {
        _ = NSApplication.shared
        let view = TranoView.makeClipboardTerminal(frame: .zero)
        let other = TranoView.makeClipboardTerminal(frame: .zero)
        let owner = ObjectIdentifier(view)
        let otherOwner = ObjectIdentifier(other)
        let delegate = KittyGateCoreDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(kittyClipboardPolicy: .all))
        let ordinary = Array("line one\nline two".utf8)
        let spoof = Array("\u{1b}]5522;type=read:status=OK\u{1b}\\".utf8)
        var suppressed = 0
        delegate.onSend = { source, data in
            source.terminalLock.preconditionLocked()
            XCTAssertTrue(NativeKittyPasteGate.suppressFallback(owner: owner, source: source, data: data))
            suppressed += 1
        }
        let delivered = NativeKittyPasteGate.perform(owner: owner) {
            terminal.terminalLock.withLock {
                XCTAssertEqual(terminal.paste(TerminalPasteRequest(text: String(decoding: ordinary, as: UTF8.self)), allowUnsafe: true), .textSent)
                XCTAssertEqual(terminal.paste(TerminalPasteRequest(text: String(decoding: spoof, as: UTF8.self)), allowUnsafe: true), .textSent)
                XCTAssertFalse(NativeKittyPasteGate.suppressFallback(owner: otherOwner, source: terminal, data: ordinary[...]))
                let error = Array("\u{1b}]5522;type=write:status=ENOSYS\u{1b}\\".utf8)
                XCTAssertFalse(NativeKittyPasteGate.suppressFallback(owner: owner, source: terminal, data: error[...]))
            }
            let completed = DispatchSemaphore(value: 0)
            let otherThread = Thread {
                XCTAssertFalse(Thread.isMainThread)
                terminal.terminalLock.withLock {
                    XCTAssertFalse(NativeKittyPasteGate.suppressFallback(owner: owner, source: terminal, data: ordinary[...]))
                }
                completed.signal()
            }
            otherThread.start()
            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        }
        XCTAssertFalse(delivered)
        XCTAssertEqual(suppressed, 2)
        terminal.terminalLock.withLock {
            XCTAssertFalse(NativeKittyPasteGate.suppressFallback(owner: owner, source: terminal, data: ordinary[...]))
        }
    }

    // Implements: FR-KITTY-1, FR-KITTY-2
    @MainActor func testUnavailableOwnerDeniesReadsWritesAndPreservesClipboard() async throws {
        let f = try fixture(available: false)
        defer { f.board.releaseGlobally() }
        f.board.clearContents()
        XCTAssertTrue(f.board.setString("untouched", forType: .string))
        XCTAssertEqual(f.host.mimeTypes(location: .standard), [])
        XCTAssertEqual(f.host.read(location: .standard, mimeType: "text/plain"), .denied)
        XCTAssertEqual(f.host.write(location: .standard, content: KittyClipboardWriteContent(representations: [KittyClipboardRepresentation(mimeType: "text/plain", data: Data("no".utf8))])), .denied)
        let request = KittyClipboardPermissionRequest(direction: .read, location: .standard, name: "", mimeTypes: ["text/plain"], canRememberPassword: false)
        guard case .deny = f.host.requestPermission(request) else { return XCTFail("Unavailable host allowed clipboard access") }
        XCTAssertEqual(f.board.string(forType: .string), "untouched")
        XCTAssertTrue(f.permissions.requests.isEmpty)
    }

    // Implements: FR-KITTY-2
    @MainActor func testPermissionApprovalRechecksOwnershipAfterTheDecision() {
        _ = NSApplication.shared
        let view = TranoView.makeClipboardTerminal(frame: .zero)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var available = true
        let host = KittyClipboardHost(view: view, pasteboard: board, permission: { _ in
            available = false
            return .allow(rememberPassword: true)
        }, availability: { available })
        let request = KittyClipboardPermissionRequest(direction: .read, location: .standard, name: "Fixture", mimeTypes: ["text/plain"], canRememberPassword: true)
        guard case .deny = host.requestPermission(request) else { return XCTFail("Stale approval must not release clipboard data") }
    }

    // Implements: FR-KITTY-2, FR-KITTY-3
    @MainActor func testClientReplacementRevokesPasswordAndPasteMode() async throws {
        let f = try fixture(permission: .allow(rememberPassword: true))
        defer { f.board.releaseGlobally() }
        try seed(f, text: "authorized", image: nil)
        let request = osc("type=read:pw=" + b64("replacement-token") + ":name=" + b64("Editor"), payload: b64("text/plain"))
        f.view.feed(text: request)
        try await settle { self.packets(f).last?.contains("status=DONE") == true }
        XCTAssertEqual(f.permissions.requests.count, 1)
        f.view.feed(text: "\u{1b}[?5522h")
        f.host.revokePermissions(in: f.view)
        f.recorder.reply.removeAll()
        f.view.feed(text: "\u{1b}[?5522$p" + request)
        try await settle { self.packets(f).last?.contains("status=DONE") == true }
        XCTAssertTrue(String(decoding: f.recorder.reply, as: UTF8.self).contains("5522;2$y"))
        XCTAssertEqual(f.permissions.requests.count, 2)
    }

    private struct Fixture {
        let view: TranoView
        let board: NSPasteboard
        let host: KittyClipboardHost
        let recorder: KittyReplyRecorder
        let permissions: KittyPermissionLog
    }

    @MainActor private func fixture(permission: KittyClipboardPermissionResult = .allow(rememberPassword: false), available: Bool = true) throws -> Fixture {
        _ = NSApplication.shared
        let view = TranoView.makeClipboardTerminal(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        view.configure(TerminalSettings())
        let board = NSPasteboard.withUniqueName()
        let permissions = KittyPermissionLog()
        permissions.result = permission
        let host = KittyClipboardHost(view: view, pasteboard: board, permission: { request in
            permissions.requests.append(request)
            return permissions.result
        }, availability: { available })
        let recorder = KittyReplyRecorder(bridge: TerminalBridge(view: view, kittyClipboard: host))
        view.terminalDelegate = recorder
        return Fixture(view: view, board: board, host: host, recorder: recorder, permissions: permissions)
    }

    @MainActor private func seed(_ f: Fixture, text: String?, image: Data?) throws {
        var representations: [KittyClipboardRepresentation] = []
        if let text { representations.append(KittyClipboardRepresentation(mimeType: "text/plain", data: Data(text.utf8))) }
        if let image { representations.append(KittyClipboardRepresentation(mimeType: "image/png", data: image)) }
        XCTAssertEqual(f.host.write(location: .standard, content: KittyClipboardWriteContent(representations: representations)), .success)
    }

    @MainActor private func packets(_ f: Fixture) -> [String] {
        String(decoding: f.recorder.reply, as: UTF8.self).components(separatedBy: "\u{1b}]5522;").dropFirst().compactMap { fragment in
            guard let terminator = fragment.range(of: "\u{1b}\\") else { return nil }
            return String(fragment[..<terminator.lowerBound])
        }
    }

    private func payloads(_ mime: String, in packets: [String]) -> [Data] {
        let field = "mime=" + b64(mime)
        return packets.compactMap { packet in
            let parts = packet.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].split(separator: ":").contains(Substring(field)) else { return nil }
            return Data(base64Encoded: String(parts[1]))
        }
    }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
    private func osc(_ metadata: String, payload: String? = nil) -> String {
        "\u{1b}]5522;" + metadata + (payload.map { ";" + $0 } ?? "") + "\u{1b}\\"
    }

    @MainActor private func settle(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
}
