import SwiftUI
import AppKit
import Observation

enum ThemeColor: String, CaseIterable, Identifiable {
    case nous, ocean, iris, rose, amber, graphite
    var id: String { rawValue }
    var title: String { ["nous":"Nous 蓝", "ocean":"海盐蓝", "iris":"鸢尾紫", "rose":"莓果粉", "amber":"蜂蜜金", "graphite":"石墨灰"][rawValue]! }
    // workspace, night workspace, night sheet, dark fill, pale accent, selection, night selection
    var colors: [UInt32] {
        switch self {
        case .nous: return [0xF6F8FA,0x010409,0x0D1117,0x0053FD,0x4A84FE,0xDEEAFF,0x1D2E4F]
        case .ocean: return [0xF6F8FA,0x010409,0x0D1117,0x006775,0x61CDDC,0xDBF0F2,0x15373E]
        case .iris: return [0xF6F8FA,0x010409,0x0D1117,0x683DB5,0xBDA0FF,0xEBE4FA,0x302547]
        case .rose: return [0xF6F8FA,0x010409,0x0D1117,0xA93660,0xF39AB8,0xF8E2EA,0x422534]
        case .amber: return [0xF6F8FA,0x010409,0x0D1117,0x895B00,0xEBC46A,0xF6EACB,0x3B321C]
        case .graphite: return [0xF6F8FA,0x010409,0x0D1117,0x43505F,0xB7C5D4,0xE3E8EE,0x2D3744]
        }
    }
    var swatch: Color { Color(nsColor: BotsPalette.rgb(colors[3])) }
}

@Observable final class VisualPreferences {
    static let shared = VisualPreferences()
    var theme: ThemeColor { didSet { UserDefaults.standard.set(theme.rawValue, forKey: "themeColor") } }
    var textScale: Double { didSet { UserDefaults.standard.set(textScale, forKey: "textScale") } }
    private init() {
        theme = ThemeColor(rawValue: UserDefaults.standard.string(forKey: "themeColor") ?? "") ?? .nous
        let saved = UserDefaults.standard.double(forKey: "textScale")
        textScale = saved.isFinite && (0.8...1.25).contains(saved) ? saved : 0.9
    }
}
extension Font {
    static func ui(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        _ = BrandTypography.register
        if design == .monospaced {
            return .custom(weight == .bold || weight == .semibold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", fixedSize: size * VisualPreferences.shared.textScale)
        }
        return .system(size: size * VisualPreferences.shared.textScale, weight: weight, design: design)
    }
}

struct ThemePreview: View {
    var theme: ThemeColor
    var dark = false
    var automatic = false
    private var c: [UInt32] { theme.colors }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                OpticalRoundedRectangle().fill(Color(nsColor: BotsPalette.rgb(dark ? c[1] : c[0])))
                OpticalRoundedRectangle().fill(Color(nsColor: BotsPalette.rgb(dark ? c[2] : 0xFFFFFF)))
                    .padding(.leading, g.size.width * 0.26).padding(7)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule().fill(Color(nsColor: BotsPalette.rgb(i == 0 ? c[3] : c[5]))).frame(width: g.size.width * 0.14, height: i == 0 ? 9 : 5)
                    }
                }.padding(.leading, 9).padding(.top, 15)
                VStack(alignment: .trailing, spacing: 8) {
                    Capsule().fill(Color(nsColor: BotsPalette.rgb(dark ? c[4] : c[3]))).frame(width: g.size.width * 0.35, height: 10)
                    OpticalRoundedRectangle().fill(Color(nsColor: BotsPalette.rgb(dark ? c[6] : c[0]))).frame(height: 26)
                    Capsule().fill(Color(nsColor: BotsPalette.rgb(dark ? c[1] : c[0]))).frame(height: 12)
                }.padding(.leading, g.size.width * 0.35).padding(.trailing, 15).padding(.top, 17)
                if automatic { Image(systemName: "circle.lefthalf.filled").font(.ui(size: 22)).foregroundStyle(Color.accent).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing) }
            }
        }.frame(height: 97).accessibilityHidden(true)
    }
}
