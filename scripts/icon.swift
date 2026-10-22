// Generates the app icon (1024 px) in the style of the macOS 26 icons:
// squircle with a deep gradient, soft highlight and shadow; in front three mixer sliders, the right one in boost orange.
// Usage: swift scripts/icon.swift <output.png>
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// Superellipse like the Apple icon shape (continuous corners).
func squircle(_ rect: CGRect, n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func linear(_ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, locations: [CGFloat]? = nil) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    cg.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(body)

// Shadow beneath the shape
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0, 0, 0, 0.35))
cg.addPath(shape)
cg.setFillColor(color(0.2, 0.2, 0.5))
cg.fillPath()
cg.restoreGState()

// Base gradient: light blue at the top, deep indigo at the bottom
cg.saveGState()
cg.addPath(shape)
cg.clip()
linear([color(0.30, 0.62, 1.0), color(0.24, 0.36, 0.96), color(0.30, 0.16, 0.70)],
       CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100), locations: [0, 0.5, 1])
// Soft light spot at the top left
let glow = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.32), color(1, 1, 1, 0)] as CFArray, locations: nil)!
cg.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 860), startRadius: 0, endCenter: CGPoint(x: 330, y: 860), endRadius: 560, options: [])
// Subtle depth at the bottom right
let shade = CGGradient(colorsSpace: space, colors: [color(0.1, 0, 0.3, 0.35), color(0.1, 0, 0.3, 0)] as CFArray, locations: nil)!
cg.drawRadialGradient(shade, startCenter: CGPoint(x: 820, y: 140), startRadius: 0, endCenter: CGPoint(x: 820, y: 140), endRadius: 520, options: [])

// Three sliders
let trackW: CGFloat = 116, trackH: CGFloat = 540, gap: CGFloat = 74
let x0 = 512 - (3 * trackW + 2 * gap) / 2, y0: CGFloat = 512 - trackH / 2 - 10
let levels: [CGFloat] = [0.46, 0.78, 0.94]
for (i, level) in levels.enumerated() {
    let x = x0 + CGFloat(i) * (trackW + gap)
    let track = CGRect(x: x, y: y0, width: trackW, height: trackH)
    let trackPath = CGPath(roundedRect: track, cornerWidth: trackW / 2, cornerHeight: trackW / 2, transform: nil)
    // Groove: dark glass with a fine edge
    cg.saveGState()
    cg.addPath(trackPath)
    cg.setFillColor(color(0.05, 0.05, 0.25, 0.28))
    cg.fillPath()
    cg.addPath(trackPath)
    cg.setStrokeColor(color(1, 1, 1, 0.18))
    cg.setLineWidth(3)
    cg.strokePath()
    cg.restoreGState()

    // Fill from the bottom
    let fill = CGRect(x: x, y: y0, width: trackW, height: max(trackW, trackH * level))
    let fillPath = CGPath(roundedRect: fill, cornerWidth: trackW / 2, cornerHeight: trackW / 2, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0.05, 0, 0.3, 0.35))
    cg.addPath(fillPath)
    cg.setFillColor(color(1, 1, 1))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(fillPath)
    cg.clip()
    if i == 2 {
        // Boost: upper part orange
        let boostStart = y0 + trackH * 0.62
        linear([color(1.0, 0.62, 0.18), color(1.0, 0.36, 0.22)], CGPoint(x: x, y: boostStart), CGPoint(x: x, y: fill.maxY))
        cg.setFillColor(color(1, 1, 1))
        cg.fill(CGRect(x: x, y: y0, width: trackW, height: boostStart - y0))
    }
    // slight gloss on the fill
    linear([color(1, 1, 1, 0), color(1, 1, 1, 0.0), color(0.85, 0.88, 1, 0.35)],
           CGPoint(x: x, y: fill.midY), CGPoint(x: x + trackW, y: fill.midY), locations: [0, 0.55, 1])
    cg.restoreGState()
}

// Glass edge: lighter edge at the top, darker at the bottom
cg.restoreGState()
cg.saveGState()
cg.addPath(shape)
cg.setLineWidth(6)
cg.replacePathWithStrokedPath()
cg.clip()
linear([color(1, 1, 1, 0.55), color(1, 1, 1, 0.08), color(0, 0, 0, 0.15)], CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100),
       locations: [0, 0.5, 1])
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
