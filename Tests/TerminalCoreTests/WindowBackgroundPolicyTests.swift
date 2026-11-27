import XCTest
@testable import TerminalCore

final class WindowBackgroundPolicyTests: XCTestCase {
    // Implements: FR-TRANSP-1, FR-TRANSP-3
    func testExplicitOpacityOverridesLegacyGlassTintWithoutChangingGeometry() {
        for style in [InterfaceSurfaceStyle.classic, .glass] {
            var prefs = InterfacePreferences(); prefs.style = style
            var context = InterfaceContext(); context.backgroundOpacity = 0.8
            let result = prefs.resolve(context)
            XCTAssertEqual(result.chromeOpacity, 0.8)
            XCTAssertEqual(result.paneOpacity, 0.8)
            XCTAssertEqual(result.headerHeight, 40)
            XCTAssertEqual(result.paneHeaderHeight, 28)
            context.backgroundOpacity = 1
            XCTAssertEqual(prefs.resolve(context).chromeOpacity, style == .glass ? 0.72 : 1)
            XCTAssertEqual(prefs.resolve(context).paneOpacity, 1)
            prefs.glassForPanes = true
            XCTAssertEqual(prefs.resolve(context).paneOpacity, style == .glass ? 0.72 : 1)
        }
    }

    // Implements: FR-TRANSP-2
    func testPerPaneOpacityAndInvalidContextRemainBounded() {
        let prefs = InterfacePreferences()
        for opacity in [0.0, 0.05, 0.1, 0.45, 0.65, 1] {
            var context = InterfaceContext(); context.backgroundOpacity = opacity
            XCTAssertEqual(prefs.resolve(context).paneOpacity, opacity)
        }
        var context = InterfaceContext(); context.backgroundOpacity = .nan
        XCTAssertEqual(prefs.resolve(context).chromeOpacity, 1)
        context.backgroundOpacity = 0
        XCTAssertEqual(prefs.resolve(context).paneOpacity, 0)
    }
}
