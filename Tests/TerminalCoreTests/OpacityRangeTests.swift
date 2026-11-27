import Foundation
import XCTest
@testable import TerminalCore

final class OpacityRangeTests: XCTestCase {
    func testZeroThroughOneValidateAndRoundTripForWindowAndProfiles() throws {
        for opacity in [0.0, 0.01, 0.1, 0.3, 0.7, 1] {
            var appearance = AppearancePreferences(); appearance.opacity = opacity
            XCTAssertNoThrow(try appearance.validate(), "\(opacity)")
            let decoded = try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(appearance))
            XCTAssertEqual(decoded.opacity, opacity)
            var settings = TerminalSettings(); settings.appearance = appearance
            settings.appearanceProfiles = [AppearanceProfile(name: "Zero allowed", settings: settings)]
            XCTAssertNoThrow(try settings.validateAppearanceProfiles(), "\(opacity)")
        }
    }
    func testOutsideUnitIntervalAndNonfiniteValuesRemainInvalid() {
        for opacity in [-0.01, 1.01, .nan, .infinity, -.infinity] {
            var appearance = AppearancePreferences(); appearance.opacity = opacity
            XCTAssertThrowsError(try appearance.validate())
        }
    }
}
