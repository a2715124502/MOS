import SwiftUI

/// Equal perceived softness across small controls, message bubbles and large surfaces.
/// Radius grows sublinearly with the shorter edge instead of sharing one point value.
enum OpticalCorners {
    static func radius(for size: CGSize) -> CGFloat {
        min(24, max(4, sqrt(max(0, min(size.width, size.height))) * 0.9)) + 2
    }
}

struct OpticalRoundedRectangle: InsettableShape {
    private var insetAmount: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: max(0, OpticalCorners.radius(for: rect.size) - insetAmount), style: .continuous)
            .path(in: rect.insetBy(dx: insetAmount, dy: insetAmount))
    }
    func inset(by amount: CGFloat) -> Self { var result = self; result.insetAmount += amount; return result }
}
