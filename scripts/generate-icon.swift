import AppKit
import ImageIO
import UniformTypeIdentifiers

enum IconError: Error {
    case rendering, encoding, conversion(Int32)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

// Letter outlines traced from Archivo Black ("T") and Pacifico ("rano"), both SIL OFL 1.1,
// in a 512-unit, y-down design space so the build needs neither font installed.
let capitalOutline = "M130.6 227.6L130.6 330.0L90.8 330.0L90.8 227.6L50.1 227.6L50.1 192.4L171.1 192.4L171.1 227.6Z"
let scriptOutline = "M147.6 330.7Q140.7 330.7 137.9 325.2Q135.1 319.6 135.1 307.5Q135.1 289.6 141.8 273.4Q143.4 269.4 147.1 267.6Q150.9 265.7 157.6 265.7Q161.2 265.7 162.6 266.4Q164.1 267.1 164.1 269.0Q164.1 271.2 161.4 278.9Q159.6 284.5 158.5 288.6Q157.4 292.7 156.7 298.8Q162.6 286.9 170.1 279.5Q177.5 272.0 184.7 268.9Q191.9 265.7 197.8 265.7Q209.6 265.7 209.6 274.7Q209.6 276.5 208.0 283.4Q206.6 288.9 206.6 290.3Q206.6 295.1 211.1 295.1Q216.2 295.1 224.2 289.0Q226.5 287.2 229.1 287.2Q231.4 287.2 232.8 288.8Q234.1 290.4 234.1 293.0Q234.1 298.1 230.5 301.0Q225.4 305.0 218.6 307.9Q211.8 310.7 204.2 310.7Q194.6 310.7 189.6 307.0Q184.6 303.2 184.6 296.9Q184.6 294.8 185.1 292.7Q185.5 290.0 185.5 289.0Q185.5 286.8 183.5 286.8Q180.8 286.8 176.3 291.4Q171.9 296.1 167.5 303.6Q163.2 311.2 160.5 319.6Q158.5 326.1 155.8 328.4Q153.2 330.7 147.6 330.7ZM239.6 330.7Q228.3 330.7 221.6 324.5Q214.9 318.3 214.9 308.2Q214.9 297.2 221.6 287.3Q228.3 277.4 239.5 271.4Q250.6 265.4 263.2 265.4Q267.2 265.4 268.5 266.6Q269.9 267.8 270.8 270.8Q274.6 270.2 278.8 270.2Q287.7 270.2 287.7 275.1Q287.7 278.0 284.9 288.9Q280.8 304.7 280.8 311.0Q280.8 313.0 282.1 314.3Q283.5 315.5 285.7 315.5Q289.1 315.5 294.0 312.1Q298.9 308.7 307.2 301.2Q309.4 299.2 312.1 299.2Q314.5 299.2 315.9 300.9Q317.2 302.5 317.2 305.4Q317.2 311.0 313.8 314.0Q306.3 321.0 298.0 325.9Q289.6 330.7 281.8 330.7Q275.9 330.7 270.9 327.6Q265.9 324.5 263.3 319.1Q253.9 330.7 239.6 330.7ZM246.1 316.8Q250.1 316.8 253.7 313.2Q257.4 309.6 259.0 303.6L265.7 278.2Q258.1 278.4 251.6 282.6Q245.2 286.8 241.4 293.7Q237.6 300.6 237.6 308.3Q237.6 312.6 239.8 314.7Q242.1 316.8 246.1 316.8ZM315.4 330.7Q308.5 330.7 305.7 325.2Q302.9 319.6 302.9 307.5Q302.9 289.6 309.6 273.4Q311.2 269.4 315.0 267.6Q318.7 265.7 325.4 265.7Q329.0 265.7 330.5 266.4Q331.9 267.1 331.9 269.0Q331.9 271.2 329.2 278.9Q327.4 284.5 326.3 288.6Q325.2 292.7 324.5 298.8Q330.5 286.9 337.9 279.5Q345.3 272.0 352.5 268.9Q359.7 265.7 365.7 265.7Q377.5 265.7 377.5 274.7Q377.5 280.0 373.5 294.1Q370.0 306.1 370.0 310.0Q370.0 315.5 375.3 315.5Q378.9 315.5 383.9 312.1Q388.9 308.7 397.2 301.2Q399.4 299.2 402.1 299.2Q404.5 299.2 405.9 300.9Q407.2 302.5 407.2 305.4Q407.2 311.0 403.8 314.0Q396.0 321.3 387.0 326.0Q378.0 330.7 366.6 330.7Q357.3 330.7 352.6 326.6Q347.9 322.5 347.9 314.8Q347.9 311.0 350.4 301.0Q352.8 292.3 352.8 289.0Q352.8 286.8 350.8 286.8Q348.4 286.8 344.2 291.4Q339.9 296.1 335.5 303.6Q331.0 311.2 328.3 319.6Q326.3 326.1 323.7 328.4Q321.0 330.7 315.4 330.7ZM423.2 330.7Q412.5 330.7 404.9 326.6Q397.4 322.5 393.6 315.9Q389.8 309.3 389.8 301.7Q389.8 291.2 395.0 283.0Q400.1 274.8 409.0 270.2Q417.9 265.6 429.0 265.6Q439.7 265.6 447.3 269.6Q454.9 273.7 458.7 280.3Q462.6 286.9 462.6 294.5Q462.6 305.0 457.3 313.2Q452.0 321.4 443.0 326.1Q434.1 330.7 423.2 330.7ZM425.2 315.8Q431.3 315.8 435.6 310.7Q439.9 305.6 439.9 295.8Q439.9 288.2 436.2 284.3Q432.6 280.5 427.5 280.5Q421.0 280.5 416.7 285.5Q412.5 290.5 412.5 300.5Q412.5 308.3 416.1 312.1Q419.7 315.8 425.2 315.8Z"

let ground = NSColor(srgbRed: 0.059, green: 0.122, blue: 0.090, alpha: 1)
let designScale: CGFloat = 832 / 512

func design(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: 96 + designScale * x, y: 928 - designScale * y)
}

func outline(_ commands: String) -> CGPath {
    let path = CGMutablePath()
    let scanner = Scanner(string: commands)
    func next() -> CGPoint {
        design(CGFloat(scanner.scanDouble() ?? 0), CGFloat(scanner.scanDouble() ?? 0))
    }
    while let command = scanner.scanCharacter() {
        switch command {
        case "M": path.move(to: next())
        case "L": path.addLine(to: next())
        case "Q":
            let control = next()
            path.addQuadCurve(to: next(), control: control)
        case "C":
            let first = next()
            let second = next()
            path.addCurve(to: next(), control1: first, control2: second)
        default: path.closeSubpath()
        }
    }
    return path
}

func brandGlyph() -> CGPath {
    let prompt = CGMutablePath()
    prompt.move(to: design(54, 250))
    prompt.addLine(to: design(78, 272))
    prompt.addLine(to: design(54, 294))
    let glyph = CGMutablePath()
    glyph.addPath(outline(capitalOutline))
    glyph.addPath(outline(scriptOutline))
    glyph.addPath(prompt.copy(strokingWithWidth: 14 * designScale, lineCap: .round, lineJoin: .round, miterLimit: 1))
    return glyph
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
    ground.setFill()
    tile.fill()
    context.restoreGState()

    let glyph = brandGlyph()
    context.setFillColor(color(0.706, 0.941, 0.290))
    context.addPath(glyph)
    context.fillPath()
    let eye = design(76, 212)
    let eyeRadius = 7 * designScale
    context.setFillColor(ground.cgColor)
    context.fillEllipse(in: CGRect(x: eye.x - eyeRadius, y: eye.y - eyeRadius, width: eyeRadius * 2, height: eyeRadius * 2))

    guard let image = context.makeImage() else { throw IconError.rendering }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError.encoding }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.encoding }
    return data as Data
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--menu-bar" {
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let glyph = brandGlyph()
    let bounds = glyph.boundingBoxOfPath
    var page = CGRect(x: 0, y: 0, width: 44, height: 16)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw IconError.rendering }
    context.beginPDFPage(nil)
    let scale = min((page.width - 2) / bounds.width, (page.height - 2) / bounds.height)
    context.translateBy(x: (page.width - bounds.width * scale) / 2,
                        y: (page.height - bounds.height * scale) / 2)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    let eye = design(76, 212), radius = 7 * designScale
    context.addRect(bounds.insetBy(dx: -1, dy: -1))
    context.addEllipse(in: CGRect(x: eye.x - radius, y: eye.y - radius, width: radius * 2, height: radius * 2))
    context.clip(using: .evenOdd)
    context.setFillColor(color(1, 1, 1))
    context.addPath(glyph)
    context.fillPath()
    context.endPDFPage()
    context.closePDF()
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (data as Data).write(to: output, options: .atomic)
    print(output.path)
    exit(0)
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
