import SwiftUI

/// Short, local animations keep streaming text and history layout stable.
enum BotMotion {
    static let quick = Animation.easeOut(duration: 0.16)
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.84)
}

struct ResponsiveButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var round = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(round ? 5 : 0)
            .frame(minWidth: round ? 36 : 30, minHeight: round ? 36 : 30)
            .contentShape(OpticalRoundedRectangle())
            .background {
                OpticalRoundedRectangle()
                    .fill(hovered && enabled ? Color.hoverFill : .clear).padding(1)
            }
            .overlay {
                OpticalRoundedRectangle().fill(Color.accent.opacity(hovered && enabled ? 0.055 : 0)).padding(1).allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : BotMotion.quick, value: configuration.isPressed)
            .animation(reduceMotion ? nil : BotMotion.quick, value: hovered)
            .onHover { hovered = $0 }
    }
}

/// Menus and tappable cards also need a visible pointer state.
private struct HoverSurface: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.background(OpticalRoundedRectangle().fill(hovered && enabled ? Color.hoverFill : .clear).padding(1))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : BotMotion.quick, value: hovered)
    }
}
extension View { func hoverSurface() -> some View { modifier(HoverSurface()) } }
