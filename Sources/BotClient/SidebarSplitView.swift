import SwiftUI
import AppKit

/// The sidebar owns its width independently of the selected conversation's layout.
struct SidebarSplitView<Sidebar: View, Detail: View>: View {
    @AppStorage("chatSidebarWidth") private var savedWidth = 224.0
    @State private var dragOrigin: CGFloat?
    @State private var draggedWidth: CGFloat?
    @State private var hovering = false
    private let sidebar: Sidebar
    private let detail: Detail
    private let minimum: CGFloat = 200
    private let maximum: CGFloat = 360
    private let dividerWidth: CGFloat = 9

    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar(); self.detail = detail()
    }

    var body: some View {
        GeometryReader { geometry in
            // A smaller window temporarily constrains the width without replacing the saved choice.
            let limit = max(minimum, min(maximum, geometry.size.width - 520 - dividerWidth))
            let preferred = savedWidth.isFinite ? CGFloat(savedWidth) : 224
            let width = clamp(draggedWidth ?? preferred, limit: limit)
            HStack(spacing: 0) {
                sidebar.frame(width: width).frame(maxHeight: .infinity)
                // Invisible resize target: the boundary is conveyed by the two surfaces.
                Color.rail
                .frame(width: dividerWidth).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if dragOrigin == nil { dragOrigin = width }
                        draggedWidth = clamp((dragOrigin ?? width) + value.translation.width, limit: limit)
                    }
                    .onEnded { value in
                        savedWidth = Double(clamp((dragOrigin ?? width) + value.translation.width, limit: limit))
                        dragOrigin = nil; draggedWidth = nil
                    })
                .onHover { value in
                    guard value != hovering else { return }
                    hovering = value
                    if value { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) { savedWidth = Double(clamp(width - 16, limit: limit)); return .handled }
                .onKeyPress(.rightArrow) { savedWidth = Double(clamp(width + 16, limit: limit)); return .handled }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("调整侧边栏宽度")
                .accessibilityValue("\(Int(width)) 点")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: savedWidth = Double(clamp(width + 16, limit: limit))
                    case .decrement: savedWidth = Double(clamp(width - 16, limit: limit))
                    @unknown default: break
                    }
                }
                .help("拖动调整侧边栏宽度，调整结果自动保存")
                detail.frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onDisappear {
            if hovering { NSCursor.pop(); hovering = false }
            dragOrigin = nil; draggedWidth = nil
        }
    }

    private func clamp(_ value: CGFloat, limit: CGFloat) -> CGFloat { min(limit, max(minimum, value)) }
}
