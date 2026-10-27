import SwiftUI
import AppKit
import HermesClient

/// Original layered artwork shared with the HTML design preview; paths compile once.
private enum GirlArtwork {
    struct SourceLayer: Decodable { let path: String; let fill: String; let stroke: String; let width: Double }
    struct Source: Decodable {
        let back: [String: [SourceLayer]]
        let front: [String: [SourceLayer]]
        let base: [String: [SourceLayer]]
        let features: [String: [SourceLayer]]
        let clip: [SourceLayer]
    }
    struct Layer { let path: Path; let fill: String; let stroke: String; let width: Double }
    static let source: Source? = {
        guard let url = Bundle.main.url(forResource: "AvatarArtwork", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Source.self, from: data)
    }()
    static let layers: [String: [Layer]] = {
        guard let source else { return [:] }
        var result: [String: [Layer]] = [:]
        for (prefix, group) in [("back", source.back), ("front", source.front), ("base", source.base), ("features", source.features)] {
            for (key, rows) in group { result[prefix + key] = rows.map { Layer(path: parse($0.path), fill: $0.fill, stroke: $0.stroke, width: $0.width) } }
        }
        result["clip"] = source.clip.map { Layer(path: parse($0.path), fill: $0.fill, stroke: $0.stroke, width: $0.width) }
        return result
    }()
    static let eye = parse("M0 5 C4 -1 14 -2 20 4 C15 12 6 13 1 9 Z")
    static let lid = parse("M0 5 C4 -1 14 -2 20 4 M1 9 C6 12 12 12 17 8")
    static let lashes = parse("M0 5 L-3 2 M1 3 L-1 0 M4 1 L3 -2 M17 2 L18 -1 M19 4 L22 2 M2 10 L1 12 M5 11 L5 13 M15 10 L16 12")
    static let upperLid = parse("M-1 4 C5 0 13 -1 20 3 L20 4 C12 1 5 3 0 6 Z")
    static let smileEye = parse("M1 7 Q9 -1 18 7")
    // Deliberately bounded path subset: absolute M, L, Q, C and Z only.
    static func parse(_ text: String) -> Path {
        let regex = try! NSRegularExpression(pattern: "[MLQCZ]|-?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)")
        let text = text as NSString
        let tokens = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }
        var path = Path(), i = 0
        func point(_ offset: Int) -> CGPoint { CGPoint(x: Double(tokens[offset]) ?? 0, y: Double(tokens[offset + 1]) ?? 0) }
        while i < tokens.count {
            let command = tokens[i]; i += 1
            let count = command == "C" ? 6 : command == "Q" ? 4 : command == "Z" ? 0 : 2
            guard i + count <= tokens.count else { return Path() }
            switch command {
            case "M": path.move(to: point(i))
            case "L": path.addLine(to: point(i))
            case "Q": path.addQuadCurve(to: point(i + 2), control: point(i))
            case "C": path.addCurve(to: point(i + 4), control1: point(i), control2: point(i + 2))
            case "Z": path.closeSubpath()
            default: return Path()
            }
            i += count
        }
        return path
    }
}

struct LocalCharacterAvatar: View {
    let style: AvatarStyle
    var size: CGFloat = 80
    var busy = false
    var animate = true
    var body: some View {
        if style.kind == .girl && GirlArtwork.source != nil {
            GirlAvatar(style: style, size: size, busy: busy, animate: animate)
        } else { CharacterAvatar(style: style, size: size, busy: busy, animate: animate) }
    }
}

struct GirlAvatar: View {
    let style: AvatarStyle
    var size: CGFloat = 80
    var busy = false
    var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var visible = false
    @State private var gaze: CGPoint?
    private var moving: Bool { animate && style.animated && !reduceMotion && visible && scenePhase == .active }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !moving)) { timeline in
            let time = moving ? timeline.date.timeIntervalSinceReferenceDate + Double(style.seed % 997) : 0
            Canvas { context, canvas in
                var c = context
                c.scaleBy(x: canvas.width / 100, y: canvas.height / 100)
                let paper = Color.white
                let sway = moving ? sin(time * (busy ? 1.35 : 0.75)) : 0
                c.translateBy(x: 50, y: 51 + sway * 0.6)
                c.rotate(by: .degrees(sway * (busy ? 1.8 : 1.1)))
                c.translateBy(x: -50, y: -50)
                if style.facing == .left { c.translateBy(x: 100, y: 0); c.scaleBy(x: -1, y: 1) }
                let ink = style.color == .charcoal ? Color.black : Color(nsColor: BotsPalette.rgb(BotsPalette.blend(style.color.rgb, 0x000000, 0.62)))
                let line = Color.black
                let face = style.facing == .front ? "front" : "right"
                func draw(_ key: String) {
                    for layer in GirlArtwork.layers[key] ?? [] {
                        func color(_ token: String) -> Color { token == "paper" ? paper : token == "ink" ? ink : line }
                        if layer.fill != "none" {
                            c.fill(layer.path, with: .color(color(layer.fill)))
                            if colorScheme == .dark && key.hasPrefix("back") && layer.fill == "ink" { c.stroke(layer.path, with: .color(.white.opacity(0.24)), lineWidth: 0.6) }
                        }
                        if layer.stroke != "none" { c.stroke(layer.path, with: .color(color(layer.stroke)), style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round)) }
                    }
                }
                draw("back" + style.hairstyle.rawValue)
                draw("base" + face)
                draw("features" + face)
                let look = moving ? (gaze ?? CGPoint(x: sin(time * 0.53) * 1.6, y: busy ? -1.4 : cos(time * 0.37) * 0.7)) : .zero
                let phase = time.truncatingRemainder(dividingBy: 5.2)
                let blink = moving && phase > 4.9 ? max(0.04, abs(phase - 5.05) / 0.15) : 1
                eyes(&c, face: face, look: look, blink: min(1, blink), ink: ink, line: line, paper: paper)
                mouth(&c, face: face, line: line)
                draw("front" + style.hairstyle.rawValue)
                draw("clip")
            }
        }
        .frame(width: size, height: size)
        .onAppear { visible = true }.onDisappear { visible = false }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): gaze = CGPoint(x: max(-2, min(2, (p.x / max(1, size) - 0.5) * 5)) * (style.facing == .left ? -1 : 1), y: max(-1.3, min(1.3, (p.y / max(1, size) - 0.5) * 3)))
            case .ended: gaze = nil
            }
        }.accessibilityHidden(true)
    }
    private func eyes(_ context: inout GraphicsContext, face: String, look: CGPoint, blink: Double, ink: Color, line: Color, paper: Color) {
        for index in 0..<2 {
            let x: CGFloat = face == "front" ? (index == 0 ? 29 : 57) : (index == 0 ? 36 : 62)
            let width: CGFloat = face == "front" ? 17 : (index == 1 ? 13 : 19)
            var c = context
            let closed = style.expression == .cheerful || style.expression == .wink && index == 1
            let openness = (style.expression == .sleepy ? 0.58 : 1) * blink
            c.translateBy(x: x, y: face == "front" ? 51 : (index == 0 ? 52 : 54)); c.scaleBy(x: width / 19, y: closed ? 1 : openness); c.translateBy(x: 0, y: -5)
            if closed {
                let smile = GirlArtwork.smileEye
                c.stroke(smile, with: .color(line), style: StrokeStyle(lineWidth: 1.6, lineCap: .round)); continue
            }
            let eye = GirlArtwork.eye
            c.fill(eye, with: .color(.white))
            var irisContext = c; irisContext.clip(to: eye)
            irisContext.fill(Path(ellipseIn: CGRect(x: 5 + look.x, y: -0.5 + look.y, width: 10, height: 12)), with: .color(ink))
            irisContext.fill(Path(ellipseIn: CGRect(x: 7.5 + look.x, y: 1 + look.y, width: 5, height: 9)), with: .color(line))
            if style.expression == .sparkle {
                var star = Path(); star.move(to: CGPoint(x: 9 + look.x, y: 1 + look.y)); star.addLine(to: CGPoint(x: 10 + look.x, y: 4 + look.y)); star.addLine(to: CGPoint(x: 13 + look.x, y: 5 + look.y)); star.addLine(to: CGPoint(x: 10 + look.x, y: 6 + look.y)); star.addLine(to: CGPoint(x: 9 + look.x, y: 9 + look.y)); star.addLine(to: CGPoint(x: 8 + look.x, y: 6 + look.y)); star.addLine(to: CGPoint(x: 5 + look.x, y: 5 + look.y)); star.addLine(to: CGPoint(x: 8 + look.x, y: 4 + look.y)); star.closeSubpath()
                irisContext.fill(star, with: .color(.white))
            } else {
                irisContext.fill(Path(ellipseIn: CGRect(x: 7 + look.x, y: 1 + look.y, width: 2.5, height: 3)), with: .color(.white))
                irisContext.fill(Path(ellipseIn: CGRect(x: 11 + look.x, y: 6 + look.y, width: 1.3, height: 1.5)), with: .color(paper))
            }
            c.fill(GirlArtwork.upperLid, with: .color(line))
            c.stroke(GirlArtwork.lid, with: .color(line), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            c.stroke(GirlArtwork.lashes, with: .color(line), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        }
    }
    private func mouth(_ c: inout GraphicsContext, face: String, line: Color) {
        let x: CGFloat = face == "front" ? 51 : 64
        var lips = Path()
        lips.move(to: CGPoint(x: x - 4.2, y: 74))
        if style.expression == .cheerful {
            lips.addQuadCurve(to: CGPoint(x: x + 4.2, y: 73.5), control: CGPoint(x: x, y: 82))
            lips.addQuadCurve(to: CGPoint(x: x - 4.2, y: 74), control: CGPoint(x: x, y: 75))
            c.fill(lips, with: .color(line))
        } else {
            lips.addQuadCurve(to: CGPoint(x: x, y: 73.6), control: CGPoint(x: x - 1.2, y: 72.2))
            lips.addQuadCurve(to: CGPoint(x: x + 4, y: 73.8), control: CGPoint(x: x + 1.8, y: 72.2))
            c.stroke(lips, with: .color(line), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            var lower = Path(); lower.move(to: CGPoint(x: x - 1.9, y: 76)); lower.addQuadCurve(to: CGPoint(x: x + 1.8, y: 76), control: CGPoint(x: x + 0.2, y: 77))
            c.stroke(lower, with: .color(line), style: StrokeStyle(lineWidth: 0.55, lineCap: .round))
        }
    }
}
