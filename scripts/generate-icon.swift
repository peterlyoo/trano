import AppKit
import ImageIO
import UniformTypeIdentifiers

enum IconError: Error {
    case rendering, encoding, conversion(Int32)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func render(pixels: Int) throws -> Data {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw IconError.rendering }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setShouldAntialias(true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let tile = NSBezierPath(roundedRect: CGRect(x: 96, y: 96, width: 832, height: 832), xRadius: 188, yRadius: 188)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0, 0, 0, 0.28))
    NSColor(srgbRed: 0.07, green: 0.09, blue: 0.08, alpha: 1).setFill()
    tile.fill()
    context.restoreGState()
    NSGradient(starting: NSColor(srgbRed: 0.14, green: 0.17, blue: 0.155, alpha: 1),
               ending: NSColor(srgbRed: 0.055, green: 0.07, blue: 0.063, alpha: 1))!
        .draw(in: tile, angle: -90)
    NSColor(srgbRed: 0.80, green: 0.93, blue: 0.86, alpha: 0.12).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let prompt = CGMutablePath()
    prompt.move(to: CGPoint(x: 286, y: 650))
    prompt.addLine(to: CGPoint(x: 424, y: 512))
    prompt.addLine(to: CGPoint(x: 286, y: 374))
    let glyph = CGMutablePath()
    glyph.addPath(prompt.copy(strokingWithWidth: 84, lineCap: .round, lineJoin: .round, miterLimit: 1))
    glyph.addRoundedRect(in: CGRect(x: 488, y: 610, width: 280, height: 96), cornerWidth: 20, cornerHeight: 20)
    glyph.addRoundedRect(in: CGRect(x: 580, y: 318, width: 96, height: 318), cornerWidth: 20, cornerHeight: 20)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 12, color: color(0, 0, 0, 0.32))
    context.setFillColor(color(0.62, 0.97, 0.83))
    context.addPath(glyph)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(glyph)
    context.clip()
    let mint = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0.43, 0.84, 0.69), color(0.72, 1, 0.88)] as CFArray,
                          locations: [0, 1])!
    context.drawLinearGradient(mint, start: CGPoint(x: 512, y: 300), end: CGPoint(x: 512, y: 720), options: [])
    context.restoreGState()

    guard let image = context.makeImage() else { throw IconError.rendering }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError.encoding }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.encoding }
    return data as Data
}

guard CommandLine.arguments.count == 2,
      URL(fileURLWithPath: CommandLine.arguments[1]).pathExtension.lowercased() == "icns" else {
    fputs("Usage: swift scripts/generate-icon.swift OUTPUT.icns\n", stderr)
    exit(2)
}

do {
    let files = FileManager.default
    let output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let directory = output.deletingLastPathComponent()
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let staging = directory.appendingPathComponent(".trano-icon-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: staging) }
    let iconset = staging.appendingPathComponent("Trano.iconset", isDirectory: true)
    try files.createDirectory(at: iconset, withIntermediateDirectories: false)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            let name = "icon_\(size)x\(size)\(suffix).png"
            try render(pixels: size * scale).write(to: iconset.appendingPathComponent(name))
        }
    }
    let stagedIcon = staging.appendingPathComponent("Trano.icns")
    let converter = Process()
    converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    converter.arguments = ["-c", "icns", iconset.path, "-o", stagedIcon.path]
    try converter.run()
    converter.waitUntilExit()
    guard converter.terminationStatus == 0 else { throw IconError.conversion(converter.terminationStatus) }
    try Data(contentsOf: stagedIcon).write(to: output, options: .atomic)
    let preview = output.deletingPathExtension().appendingPathExtension("png")
    try render(pixels: 1024).write(to: preview, options: .atomic)
    print(output.path)
    print(preview.path)
} catch {
    fputs("Icon generation failed: \(error)\n", stderr)
    exit(1)
}
