import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "跟随系统" : self == .light ? "浅色" : "深色" }
    var colorScheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
}
private struct AppTheme: ViewModifier {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme).foregroundStyle(Color.ink).tint(Color.accent)
            .buttonStyle(SecondaryButton()).toggleStyle(BotsToggleStyle()).font(.ui(size: 14))
    }
}
extension View {
    func appTheme() -> some View { modifier(AppTheme()) }
}

/// Neutral Hermes desktop surfaces with an adaptive, user-selectable accent.
enum BotsPalette {
    static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
    static func blend(_ a: UInt32, _ b: UInt32, _ ratio: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { value, shift in
            let channel = Double((a >> shift) & 255) * (1 - ratio) + Double((b >> shift) & 255) * ratio
            return value | (UInt32(channel.rounded()) << shift)
        }
    }
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        }
    }
    static let ink = adaptive(0x1F2328, 0xE6EDF3)
    static let muted = adaptive(0x59636F, 0xA3ADB9)
}
extension Color {
    private static var themeColors: [UInt32] { VisualPreferences.shared.theme.colors }
    static var accent: Color { Color(nsColor: BotsPalette.adaptive(themeColors[3], themeColors[4])) }
    static var action: Color { accent }
    static var rail: Color { Color(nsColor: BotsPalette.adaptive(themeColors[0], themeColors[1])) }
    static var canvas: Color { Color(nsColor: BotsPalette.adaptive(0xFFFFFF, themeColors[2])) }
    static var soft: Color { Color(nsColor: BotsPalette.adaptive(0xF6F8FA, 0x161B22)) }
    static var inputSurface: Color { Color(nsColor: BotsPalette.adaptive(0xF6F8FA, 0x161B22)) }
    static var elevated: Color { Color(nsColor: BotsPalette.adaptive(0xFFFFFF, 0x161B22)) }
    static var outgoing: Color { Color(nsColor: BotsPalette.adaptive(themeColors[3], themeColors[4])) }
    static var onOutgoing: Color { Color(nsColor: BotsPalette.adaptive(0xFFFFFF, themeColors[1])) }
    static var selectionFill: Color { Color(nsColor: BotsPalette.adaptive(themeColors[5], themeColors[6])) }
    static var selectionInk: Color { Color(nsColor: BotsPalette.adaptive(themeColors[3], 0xE6EDF3)) }
    static var selectionMuted: Color { Color(nsColor: BotsPalette.adaptive(BotsPalette.blend(themeColors[3], 0x202020, 0.25), 0xCBD6E6)) }
    static var selectionBorder: Color { Color(nsColor: BotsPalette.adaptive(BotsPalette.blend(themeColors[5], themeColors[3], 0.15), BotsPalette.blend(themeColors[6], themeColors[4], 0.2))) }
    static var hoverFill: Color { Color(nsColor: BotsPalette.adaptive(0xEAEFF5, 0x212A36)) }
    static var hairline: Color { Color(nsColor: BotsPalette.adaptive(0xD0D7DE, 0x30363D)) }
    static var ink: Color { Color(nsColor: BotsPalette.ink) }
    static var muted: Color { Color(nsColor: BotsPalette.muted) }
    static var activityInk: Color { Color(nsColor: BotsPalette.adaptive(0x68727D, 0x8B949E)) }
    static let botColors: [Color] = [Color(red: 0.65, green: 0.73, blue: 0.99), Color(red: 0.88, green: 0.72, blue: 0.57), Color(red: 0.67, green: 0.79, blue: 0.69), Color(red: 0.81, green: 0.71, blue: 0.94), Color(red: 0.95, green: 0.75, blue: 0.72), Color(red: 0.62, green: 0.80, blue: 0.86), Color(red: 0.90, green: 0.80, blue: 0.52)]
}
