import SwiftUI
import AppKit
import HermesClient

struct AvatarContext: Equatable {
    var gateway = "preview"
    var user = ""
    func key(_ profile: String) -> String { AvatarLibrary.key(gateway: gateway, user: user, profile: profile) }
}
private struct AvatarContextKey: EnvironmentKey { static let defaultValue = AvatarContext() }
extension EnvironmentValues {
    var avatarContext: AvatarContext {
        get { self[AvatarContextKey.self] }
        set { self[AvatarContextKey.self] = newValue }
    }
}
extension AvatarColor {
    var tint: Color { Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255) }
}

struct BotAvatar: View {
    let bot: Bot
    var size: CGFloat = 44
    var data: Data? = nil
    var busy = false
    var animate = true
    @Environment(AvatarLibrary.self) private var library
    @Environment(\.avatarContext) private var context
    var body: some View {
        let style = library.style(for: context.key(bot.profile), profile: bot.profile)
        Group {
            if style.source == .server, let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size)
                    .clipShape(OpticalRoundedRectangle())
            } else { LocalCharacterAvatar(style: style, size: size, busy: busy, animate: animate) }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if busy { Circle().fill(Color.accent).frame(width: 9, height: 9).overlay(Circle().stroke(Color.rail, lineWidth: 2)).offset(x: 1, y: 1) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(bot.name)的头像")
    }
}

/// Vector characters use one bounded timeline per visible face; no downloads or GIF decoding.
struct CharacterAvatar: View {
    let style: AvatarStyle
    var size: CGFloat = 80
    var busy = false
    var animate = true
    /// Fixed time for native preview/export. The same drawing path renders the live UI.
    var sampleTime: TimeInterval? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var gaze: CGPoint?
    private var moving: Bool { animate && style.animated && !reduceMotion && (sampleTime != nil || visible && scenePhase == .active) }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !moving || sampleTime != nil)) { timeline in
            let time = moving ? (sampleTime ?? timeline.date.timeIntervalSinceReferenceDate) + Double(style.seed % 997) : 0
            Canvas { context, canvas in
                var c = context
                c.scaleBy(x: canvas.width / 100, y: canvas.height / 100)
                let sway = moving ? sin(time * (busy ? 2 : 0.9)) : 0
                c.translateBy(x: 50, y: 51 + sway * 0.8)
                c.rotate(by: .degrees(sway * (busy ? 3 : 1.8)))
                c.scaleBy(x: 1 + sway * 0.008, y: 1 - sway * 0.008)
                c.translateBy(x: -50, y: -50)
                let body = CharacterShape(kind: style.shape).path(in: CGRect(x: 5, y: 5, width: 90, height: 90))
                c.fill(body, with: .color(style.color.tint))
                if style.color == .charcoal { c.stroke(body, with: .color(.white.opacity(0.18)), lineWidth: 0.7) }
                let look = moving ? (gaze ?? CGPoint(x: sin(time * 0.65) * 3.5, y: busy ? -4 : cos(time * 0.47) * 2)) : .zero
                let phase = time.truncatingRemainder(dividingBy: 4.8)
                let blink = moving && phase > 4.48 ? max(0.08, abs(phase - 4.64) / 0.16) : 1
                eyes(&c, look: look, blink: min(1, blink))
            }
        }
        .frame(width: size, height: size)
        .onAppear { visible = true }.onDisappear { visible = false }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): gaze = CGPoint(x: max(-4, min(4, (p.x / size - 0.5) * 12)), y: max(-3, min(3, (p.y / size - 0.5) * 9)))
            case .ended: gaze = nil
            }
        }
        .accessibilityHidden(true)
    }
    private func eyes(_ context: inout GraphicsContext, look: CGPoint, blink: Double) {
        let cream = Color(red: 1, green: 0.982, blue: 0.925)
        let ink = Color(red: 0.075, green: 0.08, blue: 0.105)
        for index in 0 ..< 2 {
            var c = context
            let x: CGFloat = index == 0 ? 28 : 53
            c.translateBy(x: x + 10.5, y: 51)
            c.scaleBy(x: 1, y: blink)
            c.translateBy(x: -10.5, y: -16)
            let white = Path(ellipseIn: CGRect(x: 0, y: 0, width: 21, height: 32))
            if style.expression == .sleepy { c.clip(to: Path(CGRect(x: -2, y: 14, width: 26, height: 32))) }
            c.fill(white, with: .color(cream))
            c.clip(to: white)
            if style.expression == .cheerful || style.expression == .wink && index == 1 {
                var line = Path()
                if style.expression == .wink {
                    line.move(to: CGPoint(x: 15, y: 11)); line.addLine(to: CGPoint(x: 7, y: 17)); line.addLine(to: CGPoint(x: 15, y: 23))
                } else {
                    line.move(to: CGPoint(x: 5, y: 20)); line.addQuadCurve(to: CGPoint(x: 16, y: 20), control: CGPoint(x: 10.5, y: 7))
                }
                c.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            } else if style.expression == .sparkle {
                let dx = look.x * 0.65, dy = look.y * 0.6
                var p = Path()
                p.move(to: CGPoint(x: 11 + dx, y: 5 + dy))
                p.addQuadCurve(to: CGPoint(x: 19 + dx, y: 17 + dy), control: CGPoint(x: 12 + dx, y: 15 + dy))
                p.addQuadCurve(to: CGPoint(x: 11 + dx, y: 28 + dy), control: CGPoint(x: 12 + dx, y: 19 + dy))
                p.addQuadCurve(to: CGPoint(x: 3 + dx, y: 17 + dy), control: CGPoint(x: 10 + dx, y: 19 + dy))
                p.addQuadCurve(to: CGPoint(x: 11 + dx, y: 5 + dy), control: CGPoint(x: 10 + dx, y: 15 + dy)); p.closeSubpath()
                c.fill(p, with: .color(ink))
            } else {
                c.fill(Path(ellipseIn: CGRect(x: 8 + look.x, y: 8 + look.y, width: 10, height: 18)), with: .color(ink))
            }
        }
        if style.shape == .heart {
            for x in [28.0, 67.0] { context.fill(Path(ellipseIn: CGRect(x: x, y: 66, width: 9, height: 5)), with: .color(.white.opacity(0.28))) }
        }
    }
}

struct CharacterShape: Shape {
    let kind: AvatarShape
    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .circle: p.addEllipse(in: CGRect(x: 4, y: 3, width: 92, height: 92))
        case .squircle: p.addRoundedRect(in: CGRect(x: 2, y: 6, width: 96, height: 88), cornerSize: CGSize(width: 29, height: 29), style: .continuous)
        case .triangle:
            p.move(to: CGPoint(x: 37, y: 11))
            p.addCurve(to: CGPoint(x: 63, y: 11), control1: CGPoint(x: 44, y: -1), control2: CGPoint(x: 56, y: -1))
            p.addLine(to: CGPoint(x: 96, y: 72))
            p.addCurve(to: CGPoint(x: 84, y: 94), control1: CGPoint(x: 106, y: 89), control2: CGPoint(x: 98, y: 94))
            p.addLine(to: CGPoint(x: 16, y: 94))
            p.addCurve(to: CGPoint(x: 4, y: 72), control1: CGPoint(x: 2, y: 94), control2: CGPoint(x: -6, y: 89)); p.closeSubpath()
        case .heart:
            p.move(to: CGPoint(x: 50, y: 94))
            p.addCurve(to: CGPoint(x: 6, y: 27), control1: CGPoint(x: 36, y: 94), control2: CGPoint(x: -7, y: 54))
            p.addCurve(to: CGPoint(x: 50, y: 23), control1: CGPoint(x: 13, y: -1), control2: CGPoint(x: 40, y: 1))
            p.addCurve(to: CGPoint(x: 94, y: 27), control1: CGPoint(x: 65, y: -2), control2: CGPoint(x: 92, y: 1))
            p.addCurve(to: CGPoint(x: 50, y: 94), control1: CGPoint(x: 108, y: 54), control2: CGPoint(x: 64, y: 94)); p.closeSubpath()
        case .pebble:
            p.move(to: CGPoint(x: 72, y: 5))
            p.addCurve(to: CGPoint(x: 97, y: 65), control1: CGPoint(x: 94, y: 1), control2: CGPoint(x: 103, y: 42))
            p.addCurve(to: CGPoint(x: 50, y: 94), control1: CGPoint(x: 96, y: 92), control2: CGPoint(x: 78, y: 93))
            p.addCurve(to: CGPoint(x: 3, y: 64), control1: CGPoint(x: 19, y: 103), control2: CGPoint(x: -10, y: 91))
            p.addCurve(to: CGPoint(x: 72, y: 5), control1: CGPoint(x: 8, y: 40), control2: CGPoint(x: 40, y: 10)); p.closeSubpath()
        case .cloud:
            p.move(to: CGPoint(x: 23, y: 91))
            p.addCurve(to: CGPoint(x: 22, y: 32), control1: CGPoint(x: -11, y: 89), control2: CGPoint(x: -7, y: 41))
            p.addCurve(to: CGPoint(x: 78, y: 32), control1: CGPoint(x: 21, y: -6), control2: CGPoint(x: 79, y: -6))
            p.addCurve(to: CGPoint(x: 77, y: 91), control1: CGPoint(x: 107, y: 41), control2: CGPoint(x: 111, y: 89))
            p.addQuadCurve(to: CGPoint(x: 50, y: 87), control: CGPoint(x: 61, y: 100))
            p.addQuadCurve(to: CGPoint(x: 23, y: 91), control: CGPoint(x: 39, y: 100)); p.closeSubpath()
        case .flower, .star:
            let count = 150
            for i in 0 ..< count {
                let a = Double(i) / Double(count) * 2 * .pi - .pi / 2
                let r: Double
                if kind == .flower {
                    // Trace the outside of five overlapping circular petals.
                    r = (0 ..< 5).map { petal -> Double in
                        let angle = Double(petal) * 2 * .pi / 5 - .pi / 2
                        let along = 23 * cos(a - angle), across = 23 * sin(a - angle)
                        return along + sqrt(max(0, 25 * 25 - across * across))
                    }.max() ?? 48
                } else { r = 39 + 9 * cos(5 * (a + .pi / 2)) }
                let point = CGPoint(x: 50 + cos(a) * r, y: 50 + sin(a) * r)
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
            p.closeSubpath()
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 100, y: rect.height / 100).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

struct AvatarPickerView: View {
    let bot: Bot
    var serverData: Data?
    @Environment(AvatarLibrary.self) private var library
    @Environment(\.avatarContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = AvatarStyle()
    @State private var loaded = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("给 \(bot.name) 一个新样子").font(.ui(size: 18, weight: .semibold))
                    Text("同一种线条，每位伙伴各有个性。").font(.ui(size: 12)).foregroundStyle(Color.muted)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    preview
                    VStack(alignment: .leading, spacing: 10) {
                        label("头像风格")
                        ChoiceTabs(selection: Binding(get: { draft.kind }, set: { draft.kind = $0; draft.source = .character }), options: AvatarKind.allCases.map { Choice($0, $0.title) })
                        if draft.source == .server { Text("当前使用 Hermes 原头像；选择风格即可改为本机头像。").font(.ui(size: 12)).foregroundStyle(Color.muted) }
                    }
                    if draft.kind == .girl { hairChoices; facingChoices } else { shapeChoices }
                    colorChoices
                    VStack(alignment: .leading, spacing: 10) {
                        label("表情")
                        ChoiceTabs(selection: Binding(get: { draft.expression }, set: { draft.expression = $0; draft.source = .character }), options: AvatarExpression.allCases.map { Choice($0, $0.title) })
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        label("灵感收藏")
                        HStack(spacing: 12) {
                            ForEach(Array(AvatarStyle.collection.enumerated()), id: \.offset) { _, preset in
                                Button { let animated = draft.animated; draft = preset; draft.animated = animated } label: {
                                    LocalCharacterAvatar(style: preset, size: 58, animate: false).padding(3)
                                }.buttonStyle(ResponsiveButton()).help("\(preset.hairstyle.title) · \(preset.expression.title)")
                            }
                        }
                    }
                    HStack {
                        Toggle("让头像动起来", isOn: $draft.animated).toggleStyle(BotsToggleStyle()).disabled(draft.source == .server)
                        Spacer()
                        if serverData != nil { Button("使用 Hermes 原头像") { draft.source = .server }.buttonStyle(ResponsiveButton()).foregroundStyle(Color.accent) }
                    }.font(.ui(size: 12))
                    Text(reduceMotion ? "系统已开启“减少动态效果”，头像保持静止。" : "眨眼、视线与轻微摆头；历史消息头像保持静态。").font(.ui(size: 12)).foregroundStyle(Color.muted)
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            Divider()
            HStack {
                Button("恢复默认") { draft = .defaultStyle(profile: bot.profile) }.buttonStyle(ResponsiveButton()).foregroundStyle(Color.muted)
                Spacer()
                Text("仅保存在这台 Mac").font(.ui(size: 12)).foregroundStyle(Color.muted)
                Button("使用这个头像") { library.set(draft, for: context.key(bot.profile)); dismiss() }.buttonStyle(FilledButton()).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 628, height: 744).background(Color.canvas).appTheme()
        .onAppear { if !loaded { draft = library.style(for: context.key(bot.profile), profile: bot.profile); loaded = true } }
    }
    private var preview: some View {
        HStack(spacing: 25) {
            Group {
                if draft.source == .server, let data = serverData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 132, height: 132).clipShape(OpticalRoundedRectangle())
                } else { LocalCharacterAvatar(style: draft, size: 132) }
            }.padding(8).background(Color.soft, in: OpticalRoundedRectangle())
            VStack(alignment: .leading, spacing: 11) {
                Text(draft.source == .server ? "Hermes 原头像" : draft.kind == .girl ? draft.hairstyle.title + " · " + draft.facing.title : draft.shape.title).font(.ui(size: 16, weight: .medium))
                Text("\(draft.color.title) · \(draft.expression.title)").font(.ui(size: 13)).foregroundStyle(Color.muted)
                Text("把指针移到头像上，她会看向你。").font(.ui(size: 12)).foregroundStyle(Color.muted).lineSpacing(4)
                Button { let kind = draft.kind; let animated = draft.animated; draft = .random(); draft.kind = kind; draft.animated = animated } label: { Label("随机搭配", systemImage: "dice") }.buttonStyle(SecondaryButton())
            }
            Spacer(minLength: 0)
        }
    }
    private var hairChoices: some View {
        VStack(alignment: .leading, spacing: 11) {
            label("发型")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                ForEach(GirlHairstyle.allCases, id: \.self) { hair in
                    let sample = hairSample(hair)
                    Button { draft.hairstyle = hair; draft.source = .character } label: {
                        HStack(spacing: 9) {
                            LocalCharacterAvatar(style: sample, size: 44, animate: false)
                            Text(hair.title).font(.ui(size: 12, weight: draft.hairstyle == hair ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }.padding(8).frame(maxWidth: .infinity).background(draft.hairstyle == hair && draft.source == .character ? Color.selectionFill : Color.soft, in: OpticalRoundedRectangle())
                    }.buttonStyle(ResponsiveButton()).accessibilityLabel("发型：\(hair.title)").accessibilityAddTraits(draft.hairstyle == hair ? .isSelected : [])
                }
            }
        }
    }
    private var facingChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("脸部朝向")
            ChoiceTabs(selection: Binding(get: { draft.facing }, set: { draft.facing = $0; draft.source = .character }), options: GirlFacing.allCases.map { Choice($0, $0.title) })
        }
    }
    private var shapeChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("几何形状")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(AvatarShape.allCases, id: \.self) { shape in
                    Button { draft.source = .character; draft.shape = shape } label: {
                        HStack { CharacterShape(kind: shape).fill(draft.color.tint).frame(width: 26, height: 26); Text(shape.title).font(.ui(size: 12)); Spacer(minLength: 0) }.padding(10)
                            .background(draft.shape == shape ? Color.selectionFill : Color.soft, in: OpticalRoundedRectangle())
                    }.buttonStyle(ResponsiveButton()).accessibilityLabel("形状：\(shape.title)")
                }
            }
        }
    }
    private var colorChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("颜色")
            HStack(spacing: 15) {
                ForEach(AvatarColor.allCases, id: \.self) { color in
                    Button { draft.source = .character; draft.color = color } label: {
                        Circle().fill(color.tint).frame(width: 28, height: 28).overlay {
                            if draft.color == color { Image(systemName: "checkmark").font(.ui(size: 11, weight: .bold)).foregroundStyle(color == .yellow || color == .mint || color == .orange ? .black : .white) }
                        }.padding(3)
                    }.buttonStyle(ResponsiveButton()).help(color.title).accessibilityLabel("颜色：\(color.title)").accessibilityAddTraits(draft.color == color ? .isSelected : [])
                }
            }
        }
    }
    private func hairSample(_ hair: GirlHairstyle) -> AvatarStyle { var s = draft; s.source = .character; s.kind = .girl; s.hairstyle = hair; return s }
    private func label(_ title: String) -> some View { Text(title).font(.ui(size: 12, weight: .medium)).foregroundStyle(Color.muted) }
}
