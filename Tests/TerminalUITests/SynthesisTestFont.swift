#if os(macOS)
import AppKit
import CoreText
import XCTest

@MainActor
func synthesisTestFont() throws -> NSFont {
    let source = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular) as CTFont
    func u16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 255), UInt8(value & 255)] }
    func u32(_ value: Int) -> [UInt8] { u16(value >> 16) + u16(value & 0xffff) }
    func tag(_ value: String) -> CTFontTableTag {
        value.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
    // Rename only the runtime copy: installed faces and font files stay intact.
    // No platform font bytes are stored in the source tree or test artifacts.
    let names = [(1, "Trano Synthesis Fixture"), (2, "Regular"),
                 (3, "TranoSynthesisFixture-Regular"), (4, "Trano Synthesis Fixture Regular"),
                 (6, "TranoSynthesisFixture-Regular"), (16, "Trano Synthesis Fixture"), (17, "Regular")]
    var nameHeader = u16(0) + u16(names.count) + u16(6 + names.count * 12)
    var nameStrings: [UInt8] = []
    for (id, name) in names {
        let bytes = name.utf16.flatMap { u16(Int($0)) }
        nameHeader += u16(3) + u16(1) + u16(0x409) + u16(id) + u16(bytes.count) + u16(nameStrings.count)
        nameStrings += bytes
    }
    var tables: [(tag: CTFontTableTag, bytes: [UInt8])] = [(tag("name"), nameHeader + nameStrings)]
    let available = try XCTUnwrap(CTFontCopyAvailableTables(source, []))
    for i in 0..<CFArrayGetCount(available) {
        let table = CTFontTableTag(UInt(bitPattern: CFArrayGetValueAtIndex(available, i)))
        guard !["name", "fvar", "avar", "gvar", "HVAR", "MVAR", "VVAR", "STAT"].map(tag).contains(table), let bytes = CTFontCopyTable(source, table, []) as Data? else { continue }
        tables.append((table, [UInt8](bytes)))
    }
    tables.sort { $0.tag < $1.tag }
    var header = u32(0x00010000) + u16(tables.count) + u16(0) + u16(0) + u16(0)
    var body: [UInt8] = []
    for table in tables {
        header += u32(Int(table.tag)) + u32(0) + u32(12 + tables.count * 16 + body.count) + u32(table.bytes.count)
        body += table.bytes + [UInt8](repeating: 0, count: (4 - table.bytes.count % 4) % 4)
    }
    let descriptor = try XCTUnwrap(CTFontManagerCreateFontDescriptorFromData(Data(header + body) as CFData))
    let font = CTFontCreateWithFontDescriptor(descriptor, 24, nil)
    XCTAssertEqual(CTFontCopyFamilyName(font) as String, "Trano Synthesis Fixture")
    XCTAssertNil(CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold))
    XCTAssertNil(CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic))
    return font as NSFont
}
#endif
