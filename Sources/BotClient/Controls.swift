import SwiftUI
import AppKit

struct FilledButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.ui(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 36)
            .foregroundStyle(Color.onOutgoing)
            .background {
                OpticalRoundedRectangle().fill(Color.outgoing)
                    .brightness(hovered && enabled ? -0.04 : 0).opacity(enabled ? 1 : 0.35)
            }
            .opacity(configuration.isPressed && enabled ? 0.78 : 1)
            .onHover { hovered = $0 }.animation(BotMotion.quick, value: hovered)
    }
}
struct SecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.ui(size: 13, weight: .medium))
            .padding(.horizontal, 13).padding(.vertical, 9).frame(minHeight: 34)
            .foregroundStyle(Color.ink.opacity(enabled ? 1 : 0.4))
            .background(hovered && enabled ? Color.hoverFill : Color.inputSurface, in: OpticalRoundedRectangle())
            .opacity(configuration.isPressed && enabled ? 0.7 : 1)
            .onHover { hovered = $0 }.animation(BotMotion.quick, value: hovered)
    }
}
struct BotsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                Capsule().fill(configuration.isOn ? Color.outgoing : Color.hairline)
                    .frame(width: 36, height: 22)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? Color.onOutgoing : Color.canvas).frame(width: 16, height: 16).padding(3)
                    }
            }.contentShape(Rectangle())
        }.buttonStyle(ResponsiveButton()).accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
            .animation(BotMotion.quick, value: configuration.isOn)
    }
}
struct BotsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.ui(size: 13)).padding(.horizontal, 12).padding(.vertical, 11)
            .background(Color.inputSurface, in: OpticalRoundedRectangle())
    }
}
struct Choice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
    init(_ value: Value, _ title: String) { self.value = value; self.title = title }
}
struct ChoicePicker<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [Choice<Value>]
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Text(options.first(where: { $0.value == selection })?.title ?? title).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.ui(size: 10, weight: .semibold)).foregroundStyle(Color.muted)
            }.font(.ui(size: 13)).padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.inputSurface, in: OpticalRoundedRectangle())
        }.buttonStyle(ResponsiveButton()).accessibilityLabel(title)
            .popover(isPresented: $open) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(options) { option in
                            Button { selection = option.value; open = false } label: {
                                HStack {
                                    Text(option.title).frame(maxWidth: .infinity, alignment: .leading)
                                    if selection == option.value { Image(systemName: "checkmark").foregroundStyle(Color.accent) }
                                }.font(.ui(size: 13)).padding(10).frame(minWidth: 145)
                                    .background(selection == option.value ? Color.selectionFill : .clear, in: OpticalRoundedRectangle())
                            }.buttonStyle(ResponsiveButton())
                        }
                    }.padding(8)
                }.frame(width: 280, height: min(310, max(56, CGFloat(options.count) * 42 + 16))).background(Color.elevated).appTheme()
            }
    }
}
struct ChoiceTabs<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [Choice<Value>]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                Button { selection = option.value } label: {
                    Text(option.title).font(.ui(size: 12, weight: selection == option.value ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.horizontal, 9).padding(.vertical, 8)
                        .foregroundStyle(selection == option.value ? Color.selectionInk : Color.muted)
                        .background(selection == option.value ? Color.selectionFill : .clear, in: OpticalRoundedRectangle())
                }.buttonStyle(ResponsiveButton())
            }
        }.padding(4).background(Color.inputSurface, in: OpticalRoundedRectangle())
    }
}
struct PopoverMenu<Label: View, Content: View>: View {
    @State private var open = false
    let content: Content
    let label: Label
    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) { self.content = content(); self.label = label() }
    var body: some View {
        Button { open.toggle() } label: { label.padding(6) }.buttonStyle(ResponsiveButton(round: true))
            .popover(isPresented: $open) {
                VStack(alignment: .leading, spacing: 5) { content }
                    .font(.ui(size: 13)).padding(12).frame(minWidth: 190).background(Color.elevated)
                    .buttonStyle(SecondaryButton()).toggleStyle(BotsToggleStyle()).appTheme()
                    .simultaneousGesture(TapGesture().onEnded { open = false })
            }
    }
}
struct NumberAdjuster: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var body: some View {
        HStack {
            Text(title).font(.ui(size: 13)); Spacer()
            Button { value = max(range.lowerBound, value - 1) } label: { Image(systemName: "minus").frame(width: 24, height: 24) }.disabled(value <= range.lowerBound)
            Text("\(value)").monospacedDigit().frame(minWidth: 35)
            Button { value = min(range.upperBound, value + 1) } label: { Image(systemName: "plus").frame(width: 24, height: 24) }.disabled(value >= range.upperBound)
        }.buttonStyle(SecondaryButton())
    }
}

struct InPageDialog<Actions: View>: View {
    let title: String
    let message: String
    let actions: Actions
    init(_ title: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.message = message; self.actions = actions()
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.18).contentShape(Rectangle()).onTapGesture { }
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.ui(size: 18, weight: .semibold))
                ScrollView { Text(message).font(.ui(size: 13)).foregroundStyle(Color.muted).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 210).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) { actions }.frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(23).frame(maxWidth: 335).background(Color.elevated, in: OpticalRoundedRectangle())
                .shadow(color: .black.opacity(0.13), radius: 24, y: 9).padding(16)
        }
    }
}

private struct SecondaryClickTarget: NSViewRepresentable {
    var action: () -> Void
    func makeNSView(context: Context) -> Target { Target() }
    func updateNSView(_ view: Target, context: Context) { view.action = action }
    final class Target: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil, let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || event.type == .leftMouseDown && event.modifierFlags.contains(.control) else { return nil }
            return self
        }
        override func rightMouseDown(with event: NSEvent) { action?() }
        override func mouseDown(with event: NSEvent) { action?() }
    }
}
private struct CustomContextMenu<Items: View>: ViewModifier {
    let items: Items
    @State private var open = false
    func body(content: Content) -> some View {
        content.overlay(SecondaryClickTarget { open = true }.accessibilityHidden(true))
            .accessibilityAction(named: Text("更多操作")) { open = true }
            .popover(isPresented: $open) {
                VStack(alignment: .leading, spacing: 6) { items }
                    .padding(10).frame(minWidth: 190).background(Color.elevated)
                    .buttonStyle(SecondaryButton()).appTheme()
                    .simultaneousGesture(TapGesture().onEnded { open = false })
            }
    }
}
extension View {
    func customContextMenu<Items: View>(@ViewBuilder items: () -> Items) -> some View { modifier(CustomContextMenu(items: items())) }
}
