import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
guard let artwork = NSImage(contentsOf: root.appendingPathComponent("Support/BrandLogo.png")) else { fatalError("Missing Support/BrandLogo.png") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let edge = CGFloat(pixels)
    let box = NSRect(x: edge * 0.04, y: edge * 0.04, width: edge * 0.92, height: edge * 0.92)
    NSBezierPath(roundedRect: box, xRadius: edge * 0.2, yRadius: edge * 0.2).addClip()
    context.imageInterpolation = .high
    artwork.draw(in: box, from: .zero, operation: .copy, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = "icon_\(size)x\(size)\(factor == 2 ? "@2x" : "").png"
        try render(size * factor).write(to: output.appendingPathComponent(name))
    }
}
