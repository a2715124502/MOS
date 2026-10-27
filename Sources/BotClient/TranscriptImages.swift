import SwiftUI
import AppKit
import ImageIO

/// Decoded thumbnails survive row reuse. Original image bytes never decode in a row body.
enum TranscriptImages {
    private final class Value: NSObject {
        let image: CGImage
        let created = Date()
        init(_ image: CGImage) { self.image = image }
    }
    private static let cache: NSCache<NSString, Value> = {
        let cache = NSCache<NSString, Value>()
        cache.countLimit = 80; cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    static func cached(_ key: String) -> CGImage? {
        guard let value = cache.object(forKey: key as NSString), Date().timeIntervalSince(value.created) < 300 else { return nil }
        return value.image
    }
    static func decode(_ data: Data, key: String) -> CGImage? {
        if let image = cached(key) { return image }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 840,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        cache.setObject(Value(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return image
    }
}

struct TranscriptImageView: View {
    let data: Data
    let cacheKey: String
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Color.clear
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(Color.muted) }
        }
        // A stable media slot prevents late decoding from changing history row heights.
        .frame(width: 280, height: 210).clipShape(OpticalRoundedRectangle())
        .task(id: cacheKey) {
            let decoded: CGImage?
            if let cached = TranscriptImages.cached(cacheKey) { decoded = cached }
            else { decoded = await Task.detached(priority: .userInitiated) { TranscriptImages.decode(data, key: cacheKey) }.value }
            guard !Task.isCancelled else { return }
            image = decoded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }
}
