import AppKit
import Speech
import SwiftTerm
import XCTest
import TerminalCore
@testable import TranoApp

final class NativeInteractionTests: XCTestCase {
    // Implements: U05, U12
    @MainActor func testAppearanceReachesNativeRenderer() throws {
        _ = NSApplication.shared
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var settings = TerminalSettings()
        settings.appearance.opacity = 0.65
        settings.appearance.foreground = "#ABCDEF"
        settings.appearance.cursorStyle = .beam
        settings.appearance.cursorBlink = false
        view.configure(settings)
        XCTAssertEqual(view.nativeBackgroundColor.alphaComponent, 0.65, accuracy: 0.001)
        XCTAssertEqual(view.nativeForegroundColor.usingColorSpace(.sRGB)?.redComponent ?? 0, 171.0 / 255, accuracy: 0.001)
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "steadyBar")
        XCTAssertEqual(view.font.pointSize, 14)
    }
    // Implements: U03, U06, U09, FR-NAV-2
    @MainActor func testNativeShortcutNormalizesPhysicalKeysAndMenuArrows() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: "+", charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 24))
        XCTAssertEqual(NativeKeyBinding.binding(for: event), "cmd+shift+=")
        let menu = NativeKeyBinding.menuEquivalent("cmd+ctrl+left")
        XCTAssertEqual(menu.0, String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        XCTAssertEqual(menu.1, [.command, .control])
    }

    // Implements: U13. Permission callbacks from a dismissed recording must not mutate the next recording.
    @MainActor func testCancelledVoicePermissionCannotUpdateNewRecording() async throws {
        var callbacks: [(SFSpeechRecognizerAuthorizationStatus) -> Void] = []
        let voice = VoiceInput(authorizeSpeech: { callbacks.append($0) }, authorizeMicrophone: { _ in XCTFail("Unexpected microphone request") })
        voice.start(); voice.stop(); voice.start()
        XCTAssertEqual(callbacks.count, 2)
        callbacks[0](.denied)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(voice.error)
        XCTAssertTrue(voice.authorizing)
        callbacks[1](.denied)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNotNil(voice.error)
        XCTAssertFalse(voice.authorizing)
    }
}
