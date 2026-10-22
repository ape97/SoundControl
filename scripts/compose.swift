// Composes README images: the raw menu snapshot hanging from a macOS 26/27-style menu bar on a soft wallpaper.
// Usage:
//   swift scripts/compose.swift <rawDir> <outDir> <colorA hex> <colorB hex> <page>...
//     rawDir holds <page>-dark.png (and <firstPage>-light.png) plus <page>-symbol.png from the app's --snapshot mode;
//     writes <outDir>/<page>-dark.png for every page and <outDir>/<firstPage>-light.png (one light image is enough).
//   swift scripts/compose.swift --frames <framesDir> <outDir> <colorA hex> <colorB hex>
//     framesDir holds frames.json and the symbol strips it names (see the app's --timeline mode); writes one dark menu
//     bar frame per entry to <outDir>/frame-NNN.png and <outDir>/frames.txt, a list for ffmpeg's concat demuxer.
// The colours are the app icon's two gradient colours. Sizes follow a MacBook menu bar (37 pt tall), measured on macOS 27.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let framesMode = args.count > 1 && args[1] == "--frames"
let a = framesMode ? Array(args.dropFirst()) : args
guard a.count >= (framesMode ? 5 : 6) else {
    FileHandle.standardError.write(Data("usage: compose.swift [--frames] rawDir outDir colorA colorB [page...]\n".utf8)); exit(2)
}
let rawDir = a[1], outDir = a[2], pages = Array(a.dropFirst(5))
let scale: CGFloat = 2, panelWidth: CGFloat = 380, margin: CGFloat = 48, barHeight: CGFloat = 37, gap: CGFloat = 6
/// Distance of the clock to the screen edge, of the open panel to the screen edge, between two menu bar items.
let edge: CGFloat = 12, panelInset: CGFloat = 10, spacing: CGFloat = 20
/// Status items carry 8 pt of their own margin on each side inside the symbol strip.
let itemMargin: CGFloat = 8

func rgb(_ hex: String) -> [CGFloat] {
    let v = UInt32(hex, radix: 16) ?? 0
    return [CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255]
}
let colorA = rgb(a[3]), colorB = rgb(a[4])
func mix(_ c: [CGFloat], _ with: CGFloat, _ t: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: c[0] + (with - c[0]) * t, green: c[1] + (with - c[1]) * t, blue: c[2] + (with - c[2]) * t, alpha: alpha)
}
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func load(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write(Data("missing \(path)\n".utf8)); exit(1)
    }
    return image
}

/// The snapshot's symbol strip has a light (top) and a dark (bottom) background; recover the ink as an alpha mask.
func symbol(_ path: String, dark: Bool) -> CGImage {
    let sheet = load(path)
    let h = sheet.height / 2, w = sheet.width
    let strip = sheet.cropping(to: CGRect(x: 0, y: dark ? h : 0, width: w, height: h))!
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(strip, in: CGRect(x: 0, y: 0, width: w, height: h))
    for i in 0..<(w * h) {
        let l = Double(px[i * 4]) / 255
        let alpha = dark ? max(0, (l - 0.16) / 0.84) : 1 - l
        let ink: UInt8 = dark ? 255 : 0
        px[i * 4] = UInt8(Double(ink) * alpha); px[i * 4 + 1] = px[i * 4]; px[i * 4 + 2] = px[i * 4]; px[i * 4 + 3] = UInt8(alpha * 255)
    }
    return ctx.makeImage()!
}

func glyph(_ name: String, ink: NSColor) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
    return NSImage(size: base.size, flipped: false) { r in base.draw(in: r); ink.set(); r.fill(using: .sourceIn); return true }
}

/// Generic system items right of the app's item, right to left: clock, Control Center, Spotlight, Wi-Fi, battery.
let systemGlyphs = ["switch.2", "magnifyingglass", "wifi", "battery.100percent"]
func clock(ink: NSColor) -> NSAttributedString {
    NSAttributedString(string: "Mon Jun 8  9:41 AM", attributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: .medium), .foregroundColor: ink])
}
/// Width from the left edge of the app's symbol strip to the right screen edge.
func clusterWidth(strip: CGFloat) -> CGFloat {
    let glyphs = systemGlyphs.compactMap { glyph($0, ink: .white) }.reduce(0) { $0 + $1.size.width + spacing }
    return strip + (spacing - itemMargin) + glyphs + clock(ink: .white).size().width + edge
}

/// Creates a top-down context (y = 0 is the top edge) of the given size in points.
func canvas(width: CGFloat, height: CGFloat) -> CGContext {
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: height); ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    return ctx
}

/// Wallpaper: a diagonal gradient in the icon's colours with two soft glows, so the scene reads like a desktop.
func wallpaper(_ ctx: CGContext, width: CGFloat, height: CGFloat, dark: Bool) {
    let base = dark ? [mix(colorB, 0, 0.62), mix(colorB, 0, 0.84)] : [mix(colorA, 1, 0.70), mix(colorB, 1, 0.74)]
    ctx.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: base as CFArray, locations: [0, 1])!,
                           start: .zero, end: CGPoint(x: width, y: height), options: [])
    for (color, center, radius) in [(colorA, CGPoint(x: width * 0.85, y: height * 0.12), max(width, height) * 0.75),
                                    (colorB, CGPoint(x: width * 0.05, y: height * 0.95), max(width, height) * 0.6)] {
        let glow = dark ? [mix(color, 0, 0.35, alpha: 0.55), mix(color, 0, 0.35, alpha: 0)]
                        : [mix(color, 1, 0.45, alpha: 0.55), mix(color, 1, 0.45, alpha: 0)]
        ctx.drawRadialGradient(CGGradient(colorsSpace: sRGB, colors: glow as CFArray, locations: [0, 1])!,
                               startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
}

/// Menu bar along the top edge: transparent as in macOS 26 and later, only a faint shade for legibility.
/// The app's symbol strip ends `rightOfStrip` points before the right edge; returns the strip's left edge.
@discardableResult
func menuBar(_ ctx: CGContext, width: CGFloat, strip: CGImage, dark: Bool, highlighted: Bool) -> CGFloat {
    let shade = dark ? [CGColor(gray: 0, alpha: 0.28), CGColor(gray: 0, alpha: 0.12)] : [CGColor(gray: 1, alpha: 0.45), CGColor(gray: 1, alpha: 0.25)]
    ctx.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: shade as CFArray, locations: [0, 1])!,
                           start: .zero, end: CGPoint(x: 0, y: barHeight), options: [])
    let ink = dark ? NSColor.white : NSColor.black
    let text = clock(ink: ink)
    var x = width - edge - text.size().width
    text.draw(at: NSPoint(x: x, y: (barHeight - text.size().height) / 2))
    for name in systemGlyphs {
        guard let g = glyph(name, ink: ink) else { continue }
        x -= spacing + g.size.width
        g.draw(in: NSRect(x: x, y: ((barHeight - g.size.height) / 2).rounded(), width: g.size.width, height: g.size.height), from: .zero,
               operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    let stripW = CGFloat(strip.width) / scale, stripH = CGFloat(strip.height) / scale
    let stripX = x - (spacing - itemMargin) - stripW
    if highlighted {   // the open item's highlight: a rounded pill around the item, inset from the bar's edges
        ctx.setFillColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.2 : 0.12))
        ctx.addPath(CGPath(roundedRect: CGRect(x: stripX + 2, y: 6, width: stripW - 4, height: barHeight - 12), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
    }
    ctx.saveGState(); ctx.translateBy(x: 0, y: barHeight); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(strip, in: CGRect(x: stripX, y: ((barHeight - stripH) / 2).rounded(), width: stripW, height: stripH)); ctx.restoreGState()
    return stripX
}

/// ImageIO adds an eXIf chunk (pixel size) even without properties; keep only the chunks needed to display the image.
func stripMetadata(_ png: Data) -> Data {
    let keep: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "sRGB"]
    var out = png.prefix(8), i = 8
    while i + 12 <= png.count {
        let length = png[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
        if keep.contains(String(decoding: png[i + 4..<i + 8], as: UTF8.self)) { out += png[i..<i + 12 + length] }
        i += 12 + length
    }
    return out
}

func write(_ ctx: CGContext, to path: String) {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
    do { try stripMetadata(data as Data).write(to: URL(fileURLWithPath: path)) } catch { exit(1) }
}

/// A page: the open panel below its highlighted menu bar item, left-aligned with the item as macOS places it,
/// pushed left where it would cross the screen edge.
func compose(page: String, dark: Bool) {
    let panel = load("\(rawDir)/\(page)-\(dark ? "dark" : "light").png")
    // Each page shows the menu bar symbol of its own state; the first page's symbol stands in where a page has none.
    let own = "\(rawDir)/\(page)-symbol.png"
    let strip = symbol(FileManager.default.fileExists(atPath: own) ? own : "\(rawDir)/\(pages[0])-symbol.png", dark: dark)
    let panelHeight = CGFloat(panel.height) / scale
    let cluster = clusterWidth(strip: CGFloat(strip.width) / scale)
    let width = max(margin + panelWidth + panelInset, cluster + margin), height = barHeight + gap + panelHeight + margin
    let ctx = canvas(width: width, height: height)
    wallpaper(ctx, width: width, height: height, dark: dark)
    let stripX = menuBar(ctx, width: width, strip: strip, dark: dark, highlighted: true)

    let rect = CGRect(x: min(stripX + itemMargin, width - panelInset - panelWidth), y: barHeight + gap, width: panelWidth, height: panelHeight)
    let radius: CGFloat = 14
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 32, color: CGColor(gray: 0, alpha: dark ? 0.6 : 0.3))
    ctx.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 1, alpha: 1))
    ctx.addPath(path); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.translateBy(x: 0, y: rect.minY + rect.height); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(panel, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.2 : 0.12)); ctx.setLineWidth(0.5)
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), cornerWidth: radius - 0.25, cornerHeight: radius - 0.25, transform: nil))
    ctx.strokePath()

    let path2 = "\(outDir)/\(page)-\(dark ? "dark" : "light").png"
    write(ctx, to: path2)
    print(path2)
}

/// One frame of a menu bar animation: {"symbol": file, "duration": seconds, "caption": text, "cursor": [dx, dy]}.
/// The cursor's hotspot sits dx points left of the strip's right edge and dy below the screen's top edge.
struct Frame: Decodable { let symbol: String; let duration: Double; let caption: String?; let cursor: [CGFloat]? }

/// The standard black arrow pointer with its white outline, tip at `tip`. Drawn rather than taken from NSCursor, whose
/// image follows the pointer colours set in the system's accessibility settings.
func arrow(_ ctx: CGContext, at tip: CGPoint) {
    let points: [CGPoint] = [(0, 0), (0, 16.5), (4, 12.8), (6.7, 18.8), (9.4, 17.6), (6.8, 11.8), (12, 11.8)].map { CGPoint(x: tip.x + $0.0, y: tip.y + $0.1) }
    let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: CGColor(gray: 0, alpha: 0.45))
    ctx.setLineJoin(.round); ctx.setLineWidth(2.2); ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(path); ctx.strokePath()
    ctx.restoreGState()
    ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.addPath(path); ctx.fillPath()
}

func composeFrames() {
    guard let data = FileManager.default.contents(atPath: "\(rawDir)/frames.json"),
          let frames = try? JSONDecoder().decode([Frame].self, from: data), !frames.isEmpty else {
        FileHandle.standardError.write(Data("missing or invalid \(rawDir)/frames.json\n".utf8)); exit(1)
    }
    let strips = frames.map { symbol("\(rawDir)/\($0.symbol)", dark: true) }
    let widest = strips.map { CGFloat($0.width) / scale }.max()!
    let width = (clusterWidth(strip: widest) + 140).rounded(), height = barHeight + 46
    var list = ""
    for (i, frame) in frames.enumerated() {
        let ctx = canvas(width: width, height: height)
        wallpaper(ctx, width: width, height: height, dark: true)
        let stripX = menuBar(ctx, width: width, strip: strips[i], dark: true, highlighted: false)
        if let caption = frame.caption, !caption.isEmpty {
            let shadow = NSShadow(); shadow.shadowBlurRadius = 6; shadow.shadowColor = NSColor(white: 0, alpha: 0.5)
            let style = NSMutableParagraphStyle(); style.alignment = .center
            NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .shadow: shadow,
                                                             .foregroundColor: NSColor(white: 1, alpha: 0.92), .paragraphStyle: style])
                .draw(in: NSRect(x: 0, y: barHeight + 13, width: width, height: 22))
        }
        if let c = frame.cursor, c.count == 2 {
            arrow(ctx, at: CGPoint(x: stripX + CGFloat(strips[i].width) / scale - c[0], y: c[1]))
        }
        let name = String(format: "frame-%03d.png", i)
        write(ctx, to: "\(outDir)/\(name)")
        list += "file '\(name)'\nduration \(frame.duration)\n"
    }
    // The concat demuxer ignores the last entry's duration unless the file is listed once more.
    list += "file '\(String(format: "frame-%03d.png", frames.count - 1))'\n"
    try? list.write(toFile: "\(outDir)/frames.txt", atomically: true, encoding: .utf8)
    print("\(outDir)/frames.txt (\(frames.count) frames)")
}

if framesMode {
    composeFrames()
} else {
    for (i, page) in pages.enumerated() {
        compose(page: page, dark: true)
        if i == 0 { compose(page: page, dark: false) }
    }
}
