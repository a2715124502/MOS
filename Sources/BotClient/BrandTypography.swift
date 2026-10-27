import SwiftUI
import CoreText

/// Hermes desktop uses platform UI text and JetBrains Mono for technical text.
enum BrandTypography {
    static let register: Void = {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}
struct BrandWordmark: View {
    var size: CGFloat = 25
    var body: some View {
        Text("MOS").font(.system(size: size * VisualPreferences.shared.textScale, weight: .bold).width(.condensed)).tracking(-0.6)
            .lineLimit(1).minimumScaleFactor(0.72)
    }
}
