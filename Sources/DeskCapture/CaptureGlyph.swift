import SwiftUI

/// Small vector studies of the tools: motion follows the pointer, never a timer.
struct CaptureGlyph: View {
    enum Kind { case region, text, scrolling, windowScrolling, recording, collection }
    var kind: Kind = .region
    var tint: Color = Palette.ice
    var size: CGFloat = 36
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var engaged: Bool { active && !reduceMotion }

    var body: some View {
        ZStack {
            switch kind {
            case .region:
                RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.12))
                    .frame(width: size * 0.64, height: size * 0.48)
                    .rotationEffect(.degrees(engaged ? -6 : -12)).offset(x: -size * 0.08, y: size * 0.05)
                RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.45), lineWidth: 1)
                    .frame(width: size * 0.59, height: size * 0.44)
                    .rotationEffect(.degrees(engaged ? 3 : 9)).offset(x: size * 0.08, y: -size * 0.05)
                Image(systemName: "viewfinder").font(.system(size: size * 0.78, weight: .light))
                    .scaleEffect(engaged ? 1.06 : 1)
                Circle().fill(tint).frame(width: size * 0.08, height: size * 0.08)
            case .text, .scrolling:
                RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.55), lineWidth: 1)
                    .frame(width: size * 0.59, height: size * 0.76)
                VStack(alignment: .leading, spacing: size * 0.09) {
                    ForEach(0..<3) { row in
                        Capsule().fill(tint.opacity(row == 1 ? 0.8 : 0.4))
                            .frame(width: size * (row == 2 ? 0.23 : 0.35), height: 1.5)
                    }
                }.offset(y: kind == .scrolling && engaged ? -size * 0.08 : 0)
                if kind == .text {
                    Capsule().fill(tint).frame(width: size * 0.76, height: 2)
                        .offset(y: size * (engaged ? 0.23 : -0.22))
                } else {
                    Image(systemName: "arrow.down").font(.system(size: size * 0.31, weight: .semibold))
                        .padding(2).background(Palette.ink, in: Circle())
                        .offset(x: size * 0.24, y: size * (engaged ? 0.28 : 0.18))
                }
            case .windowScrolling:
                RoundedRectangle(cornerRadius: size * 0.12)
                    .fill(tint.opacity(0.09))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.12).strokeBorder(tint.opacity(0.65), lineWidth: 1.2))
                    .frame(width: size * 0.83, height: size * 0.65)
                Rectangle().fill(tint.opacity(0.25)).frame(width: size * 0.80, height: 1)
                    .offset(y: -size * 0.14)
                HStack(spacing: size * 0.06) {
                    Circle().fill(tint); Circle().fill(tint.opacity(0.45))
                }.frame(width: size * 0.14, height: size * 0.04).offset(x: -size * 0.22, y: -size * 0.23)
                Image(systemName: "arrow.down").font(.system(size: size * 0.28, weight: .medium))
                    .offset(y: size * (engaged ? 0.16 : 0.08))
            case .recording:
                Circle().stroke(tint.opacity(0.35), lineWidth: 1).frame(width: size * 0.77)
                Circle().trim(from: 0.05, to: 0.75).stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: size * 0.77).rotationEffect(.degrees(engaged ? 65 : -15))
                RoundedRectangle(cornerRadius: engaged ? 3 : size * 0.2).fill(tint)
                    .frame(width: size * (engaged ? 0.29 : 0.36), height: size * (engaged ? 0.29 : 0.36))
            case .collection:
                ForEach(0..<3) { layer in
                    RoundedRectangle(cornerRadius: size * 0.09)
                        .fill(Palette.ink)
                        .overlay(RoundedRectangle(cornerRadius: size * 0.09).stroke(tint.opacity(0.3 + Double(layer) * 0.2), lineWidth: 1))
                        .frame(width: size * 0.7, height: size * 0.5)
                        .rotationEffect(.degrees(Double(layer - 1) * (engaged ? 14 : 9)))
                        .offset(x: CGFloat(layer - 1) * size * 0.09, y: CGFloat(layer - 1) * size * 0.09)
                }
                Image(systemName: "viewfinder").font(.system(size: size * 0.25, weight: .light)).offset(x: size * 0.09, y: size * 0.09)
            }
        }.foregroundStyle(tint).frame(width: size, height: size)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: active)
            .accessibilityHidden(true).allowsHitTesting(false)
    }
}

/// Proportional corners remain readable in a menu-bar mark or a large frame.
struct CaptureFrameShape: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.28
        var path = Path()
        for (x, y, dx, dy) in [(rect.minX, rect.minY, CGFloat(1), CGFloat(1)),
                               (rect.maxX, rect.minY, -1, 1),
                               (rect.minX, rect.maxY, 1, -1),
                               (rect.maxX, rect.maxY, -1, -1)] {
            path.move(to: CGPoint(x: x, y: y + dy * length))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + dx * length, y: y))
        }
        return path
    }
}

/// The entry and empty state share one friendly little photograph.
struct CaptureEntryArtwork: View {
    var active: Bool
    var body: some View {
        CaptureKeepsakeArtwork(size: 72, active: active).frame(width: 80, height: 80)
    }
}

struct CaptureSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// Code-native artwork stays crisp at every scale. The face is decorative;
/// real labels, progress and errors remain direct and functional.
struct CaptureKeepsakeArtwork: View {
    var size: CGFloat = 120
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private var engaged: Bool { active && !reduceMotion }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.11, style: .continuous)
                .fill(Palette.apricot.opacity(0.42))
                .frame(width: size * 0.60, height: size * 0.72)
                .rotationEffect(.degrees(engaged ? -7 : -12)).offset(x: -size * 0.07, y: size * 0.025)
            VStack(spacing: size * 0.07) {
                portrait
                    .frame(width: size * 0.48, height: size * 0.44)
                HStack(spacing: size * 0.035) {
                    Capsule().fill(Palette.ice.opacity(0.35)).frame(width: size * 0.14, height: size * 0.025)
                    Capsule().fill(Palette.ice.opacity(0.15)).frame(width: size * 0.07, height: size * 0.025)
                    Spacer(minLength: 0)
                }.frame(width: size * 0.46)
            }
            .padding(size * 0.065)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: size * 0.10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.10, style: .continuous)
                .strokeBorder(contrast == .increased ? Palette.separator : Palette.ice.opacity(0.17), lineWidth: 1))
            .shadow(color: .black.opacity(0.09), radius: size * 0.035, x: 0, y: size * 0.04)
            .rotationEffect(.degrees(engaged ? 0 : 5)).offset(x: size * 0.035, y: -size * 0.02)
        }.frame(width: size, height: size)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: active)
            .accessibilityHidden(true).allowsHitTesting(false)
    }
    private var portrait: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                Palette.ice.opacity(0.10)
                Circle().fill(Palette.apricot.opacity(0.55)).frame(width: w * 0.18, height: w * 0.18)
                    .position(x: w * 0.80, y: h * 0.22)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.88))
                    path.addQuadCurve(to: CGPoint(x: w, y: h * 0.76), control: CGPoint(x: w * 0.35, y: h * 0.39))
                    path.addLine(to: CGPoint(x: w, y: h)); path.addLine(to: CGPoint(x: 0, y: h))
                    path.closeSubpath()
                }.fill(Palette.sage.opacity(0.32))
                HStack(spacing: w * 0.16) {
                    Capsule().frame(width: w * 0.055, height: h * 0.115)
                    Capsule().frame(width: w * 0.055, height: h * 0.115)
                }.foregroundStyle(Palette.ice).position(x: w * 0.49, y: h * 0.42)
                CaptureSmile().stroke(Palette.ice, style: StrokeStyle(lineWidth: max(1, w * 0.028), lineCap: .round))
                    .frame(width: w * 0.17, height: h * 0.085).position(x: w * 0.49, y: h * 0.55)
                HStack(spacing: w * 0.32) {
                    Ellipse(); Ellipse()
                }.foregroundStyle(Palette.apricot.opacity(0.48))
                    .frame(width: w * 0.52, height: h * 0.055).position(x: w * 0.49, y: h * 0.52)
            }.clipShape(RoundedRectangle(cornerRadius: size * 0.055, style: .continuous))
        }
    }
}
