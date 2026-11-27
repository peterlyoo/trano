import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class TabIconColorTests: XCTestCase {
    // Implements: FR-NAV-9, FR-NAV-11
    func testOrdinaryShellAndZshUseTheSameDarkTerminalWithGreenPrompt() throws {
        for scheme in [ColorScheme.dark, .light] {
            let shell = try pixels(ProgramLogo(program: .shell).environment(\.colorScheme, scheme))
            let zsh = try pixels(ProgramLogo(program: .zsh).environment(\.colorScheme, scheme))
            XCTAssertTrue(zsh == shell, "zsh and ordinary shell must share the terminal icon")
            for bytes in [shell, zsh] {
                var dark = 0, green = 0, orange = 0
                for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 200 {
                    let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
                    if max(r, g, b) < 85 { dark += 1 }
                    if g > 120 && g > r * 5 / 4 && g > b * 11 / 10 { green += 1 }
                    if r > 100 && r > g * 7 / 5 && r > b * 7 / 5 { orange += 1 }
                }
                XCTAssertGreaterThan(dark, 300, "The terminal body must stay dark in either theme")
                XCTAssertGreaterThan(green, 20, "The terminal prompt must be green")
                XCTAssertEqual(orange, 0, "The orange zsh mark must not appear for an ordinary terminal")
            }
        }
    }

    // Implements: FR-NAV-9, FR-NAV-11; regression default icon color parity
    func testDefaultTabColorsMatchNaturalLogosWithoutWhiteBadgeBacking() throws {
        for scheme in [ColorScheme.dark, .light] {
            for program in [TerminalProgram.shell, .claude, .codex, .zsh, .k9s, .kubernetesExec] {
                let reference = try pixels(ProgramLogo(program: program).environment(\.colorScheme, scheme))
                let tab = try pixels(TabAgentIcons(programs: [program]).environment(\.colorScheme, scheme))
                let expected = statistics(reference), actual = statistics(tab)
                XCTAssertGreaterThan(expected.alpha, 0, program.rawValue)
                XCTAssertEqual(actual.red, expected.red, accuracy: 0.05, "\(program) \(scheme) red")
                XCTAssertEqual(actual.green, expected.green, accuracy: 0.05, "\(program) \(scheme) green")
                XCTAssertEqual(actual.blue, expected.blue, accuracy: 0.05, "\(program) \(scheme) blue")
                XCTAssertLessThanOrEqual(actual.alpha, expected.alpha * 1.15, "\(program) acquired a solid backing")
            }
        }
    }

    // Implements: FR-SET-38, FR-SET-39
    func testExplicitMonochromeAndShellAccentOverridesStillReachLogoWithoutBadge() throws {
        var monochrome = TabAgentIcons(programs: [.claude])
        monochrome.colored = false
        monochrome.themeForeground = Color(red: 0.1, green: 0.7, blue: 0.3)
        let reference = statistics(try pixels(ProgramLogo(program: .claude, tint: monochrome.themeForeground)))
        let actual = statistics(try pixels(monochrome))
        XCTAssertEqual(actual.red, reference.red, accuracy: 0.05)
        XCTAssertEqual(actual.green, reference.green, accuracy: 0.05)
        XCTAssertEqual(actual.blue, reference.blue, accuracy: 0.05)
        var accent = TabAgentIcons(programs: [.zsh])
        accent.shellTheme = .accent
        accent.themeAccent = Color(red: 0.8, green: 0.2, blue: 0.7)
        let expected = statistics(try pixels(ProgramLogo(program: .zsh, tint: accent.themeAccent, monochrome: true)))
        let result = statistics(try pixels(accent))
        XCTAssertEqual(result.red, expected.red, accuracy: 0.05)
        XCTAssertEqual(result.green, expected.green, accuracy: 0.05)
        XCTAssertEqual(result.blue, expected.blue, accuracy: 0.05)
    }

    // Implements: FR-NAV-9
    func testNaturalColorsPreserveCompactStackAndEmptyLimit() throws {
        let icons = TabAgentIcons(programs: [.claude, .codex, .zsh])
        let image = try XCTUnwrap(ImageRenderer(content: icons).cgImage)
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 16)
        var hidden = icons; hidden.limit = 0
        XCTAssertNil(ImageRenderer(content: hidden).cgImage)
    }

    private struct PixelStats {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }
    private func pixels<V: View>(_ content: V) throws -> [UInt8] {
        let renderer = ImageRenderer(content: content); renderer.scale = 4
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private func statistics(_ pixels: [UInt8]) -> PixelStats {
        var r = 0.0, g = 0.0, b = 0.0, alpha = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            r += Double(pixels[index]); g += Double(pixels[index + 1]); b += Double(pixels[index + 2]); alpha += Double(pixels[index + 3])
        }
        return PixelStats(red: r / max(1, alpha), green: g / max(1, alpha), blue: b / max(1, alpha), alpha: alpha / 255)
    }
}
