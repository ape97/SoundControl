import SwiftUI

/// Slider in the style of Control Center: capsule, the fill shows the value, the symbol sits inside.
struct CapsuleSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var symbol: String? = nil
    var symbolValue: Double? = nil
    var height: CGFloat = 24
    var tint: Color = .primary
    var dimmed = false
    /// Value at which the slider snaps (e.g. 100 %), with a subtle marker.
    var detent: Double? = nil
    /// From here the fill turns orange: amplification above 100 %.
    var boostFrom: Double? = nil
    /// Fill starts here instead of at the left (e.g. balance center).
    var origin: Double? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private func fraction(_ v: Double) -> Double {
        min(max((v - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = fraction(value)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.primary.opacity(scheme == .dark ? 0.13 : 0.08))

                if let origin {
                    let o = fraction(origin) * w, x = f * w
                    Capsule(style: .continuous)
                        .fill(fillStyle)
                        .frame(width: max(abs(x - o), 3))
                        .offset(x: min(x, o) - (abs(x - o) < 3 ? 1.5 : 0))
                } else {
                    let fillWidth = max(height, w * f)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(fillStyle)
                        if let boostFrom, value > boostFrom {
                            let start = fraction(boostFrom) * w
                            LinearGradient(colors: [.orange, Color(red: 1, green: 0.35, blue: 0.2)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: max(fillWidth - start, 0))
                                .offset(x: start)
                        }
                    }
                    .frame(width: fillWidth)
                    .clipShape(Capsule(style: .continuous))
                    .opacity(f <= 0 ? 0 : 1)
                }

                if let detent, abs(value - detent) > 0.001 {
                    let x = w * fraction(detent)
                    Capsule()
                        .fill(.primary.opacity(0.28))
                        .frame(width: 1.5, height: height * 0.42)
                        .offset(x: x - 0.75)
                }

                if let symbol {
                    Image(systemName: symbol, variableValue: symbolValue)
                        .font(.system(size: height * 0.44, weight: .semibold))
                        .foregroundStyle(f * w > height * 0.9 && origin == nil ? symbolOnFill : Color.secondary)
                        .frame(width: height, height: height)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        set(x: g.location.x, width: w)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: height)
        .scaleEffect(y: dragging ? 1.12 : 1, anchor: .center)
        .brightness(hovering && !dragging ? (scheme == .dark ? 0.04 : -0.02) : 0)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
        .animation(dragging ? nil : .snappy(duration: 0.18), value: value)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.5 : 1)
    }

    private var fillStyle: AnyShapeStyle {
        if tint == .primary {
            return AnyShapeStyle(scheme == .dark ? Color.white.opacity(0.9) : Color.white)
        }
        return AnyShapeStyle(tint.gradient)
    }

    private var symbolOnFill: Color {
        tint == .primary ? Color.black.opacity(0.6) : .white
    }

    /// Half width of the snap zone in points. Fixed in points rather than percent: 99 % and 101 % stay directly
    /// reachable next to the zone (a percentage-based zone used to snap everything between 95 and 105 %).
    private let detentZone: Double = 4

    private func set(x: CGFloat, width: CGFloat) {
        let w = max(Double(width), 1), px = min(max(Double(x), 0), w)
        let lo = range.lowerBound, hi = range.upperBound
        var v = lo + px / w * (hi - lo)
        if let detent, detent > lo, detent < hi {
            // Snap zone around the snap point; left and right of it the remaining travel is distributed evenly over the values.
            let d = fraction(detent) * w, left = d - detentZone, right = d + detentZone
            if px < left {
                v = lo + px / max(left, 1) * (detent - lo)
            } else if px > right {
                v = detent + (px - right) / max(w - right, 1) * (hi - detent)
            } else {
                if value != detent { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                v = detent
            }
        }
        // Whole percent so values such as 98 % or 99 % stay exactly where set.
        value = min(max((v * 100).rounded() / 100, lo), hi)
    }
}
