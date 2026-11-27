import Foundation
import SwiftTerm
import XCTest

private final class DeferredPasteSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (KittyClipboardReadResult) -> Void)?
    let requested = XCTestExpectation(description: "Snapshot content requested")

    func read(_ mime: String, completion: @escaping @Sendable (KittyClipboardReadResult) -> Void) -> Bool {
        lock.lock(); self.completion = completion; lock.unlock()
        requested.fulfill()
        return true
    }
    func finish(_ result: KittyClipboardReadResult) {
        lock.lock(); let completion = self.completion; self.completion = nil; lock.unlock()
        completion?(result)
    }
}

private final class DeferredPasteRecorder: TerminalDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(user: Bool, bytes: [UInt8])] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { record(user: false, bytes: data) }
    func sendUserInput(source: Terminal, data: ArraySlice<UInt8>) { record(user: true, bytes: data) }
    private func record(user: Bool, bytes: ArraySlice<UInt8>) {
        lock.lock(); events.append((user, Array(bytes))); lock.unlock()
    }
    var values: [(user: Bool, bytes: [UInt8])] {
        lock.lock(); defer { lock.unlock() }; return events
    }
    func kittyClipboardCapabilities(source: Terminal) -> KittyClipboardCapabilities { .standard }
    func kittyClipboardAvailableMimeTypes(source: Terminal, location: KittyClipboardLocation,
        completion: @escaping @Sendable ([String]?) -> Void) -> Bool {
        completion(["text/plain"]); return true
    }
    func kittyClipboardRead(source: Terminal, location: KittyClipboardLocation, mimeType: String,
        completion: @escaping @Sendable (KittyClipboardReadResult) -> Void) -> Bool {
        completion(.data(Data("plain fixture".utf8))); return true
    }
    func kittyClipboardRequestPermission(source: Terminal, request: KittyClipboardPermissionRequest,
        completion: @escaping @Sendable (KittyClipboardPermissionResult) -> Void) -> Bool {
        completion(.allow(rememberPassword: false)); return true
    }
}

final class DeferredKittyPasteInputTests: XCTestCase {
    // Implements: FR-QUEUE-5
    func testDelayedTokenContentAfterManualSubmitStillCountsAsUserInput() async throws {
        let reader = DeferredPasteSnapshot()
        let recorder = DeferredPasteRecorder()
        let terminal = Terminal(delegate: recorder, options: TerminalOptions(kittyClipboardPolicy: .all))
        let token = try makePaste(terminal, recorder: recorder, reader: reader)
        terminal.terminalLock.withLock { terminal.feed(text: read(token: token, mime: "text/plain")) }
        await fulfillment(of: [reader.requested], timeout: 2)
        terminal.terminalLock.withLock { terminal.sendUserInput([13][...]) }
        XCTAssertEqual(recorder.values.count, 2)
        reader.finish(.data(Data("late 한글 draft".utf8)))
        try await waitForCount(3, in: recorder)
        let events = recorder.values
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events[2].user, "Delayed paste content must invalidate the post-submit clean revision")
        XCTAssertTrue(String(decoding: events[2].bytes, as: UTF8.self).contains("status=DATA"))
        XCTAssertTrue(String(decoding: events[2].bytes, as: UTF8.self).contains(Data("late 한글 draft".utf8).base64EncodedString()))
        XCTAssertTrue(events.allSatisfy(\.user))
    }

    // Implements: FR-QUEUE-5
    func testFailedTokenReadStatusRemainsProtocolResponse() async throws {
        let reader = DeferredPasteSnapshot()
        let recorder = DeferredPasteRecorder()
        let terminal = Terminal(delegate: recorder, options: TerminalOptions(kittyClipboardPolicy: .all))
        let token = try makePaste(terminal, recorder: recorder, reader: reader)
        terminal.terminalLock.withLock { terminal.feed(text: read(token: token, mime: "text/plain")) }
        await fulfillment(of: [reader.requested], timeout: 2)
        reader.finish(.denied)
        try await waitForCount(2, in: recorder)
        let events = recorder.values
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].user)
        XCTAssertFalse(events[1].user)
        XCTAssertEqual(String(decoding: events[1].bytes, as: UTF8.self), "\u{1b}]5522;type=read:status=EPERM\u{1b}\\")
    }

    // Implements: FR-QUEUE-5
    func testOrdinaryReadAndTypeListSuccessRemainProtocolResponses() async throws {
        let recorder = DeferredPasteRecorder()
        let terminal = Terminal(delegate: recorder, options: TerminalOptions(kittyClipboardPolicy: .all))
        terminal.terminalLock.withLock { terminal.feed(text: read(token: nil, mime: "text/plain")) }
        try await waitForCount(1, in: recorder)
        terminal.terminalLock.withLock { terminal.feed(text: read(token: nil, mime: ".")) }
        try await waitForCount(2, in: recorder)
        XCTAssertEqual(recorder.values.count, 2)
        XCTAssertTrue(recorder.values.allSatisfy { !$0.user })
        XCTAssertTrue(recorder.values.allSatisfy { String(decoding: $0.bytes, as: UTF8.self).contains("status=DONE") })
    }

    private func makePaste(_ terminal: Terminal, recorder: DeferredPasteRecorder,
        reader: DeferredPasteSnapshot) throws -> String {
        let snapshot = TerminalClipboardSnapshot(location: .standard, mimeTypes: ["text/plain"], read: { mime, completion in
            reader.read(mime, completion: completion)
        })
        terminal.terminalLock.withLock {
            terminal.feed(text: "\u{1b}[?5522h")
            XCTAssertEqual(terminal.paste(TerminalPasteRequest(snapshot: snapshot)), .eventSent)
        }
        let event = try XCTUnwrap(recorder.values.first)
        XCTAssertTrue(event.user)
        let metadata = String(decoding: event.bytes, as: UTF8.self).components(separatedBy: "\u{1b}\\")[0]
        let field = try XCTUnwrap(metadata.split(separator: ":").first { $0.hasPrefix("pw=") })
        return String(field.dropFirst(3))
    }

    private func read(token: String?, mime: String) -> String {
        let password = token.map { ":pw=" + $0 + ":name=" + Data("Fixture".utf8).base64EncodedString() } ?? ""
        return "\u{1b}]5522;type=read" + password + ";" + Data(mime.utf8).base64EncodedString() + "\u{1b}\\"
    }

    private func waitForCount(_ count: Int, in recorder: DeferredPasteRecorder) async throws {
        let deadline = Date().addingTimeInterval(2)
        while recorder.values.count < count && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(recorder.values.count, count)
    }
}
