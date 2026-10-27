import SwiftUI
import AppKit
import ImageIO
import HermesClient

struct ComposerAttachmentView: View {
    let item: ChatAttachment
    var remove: () -> Void
    @State private var hovered = false
    @State private var thumbnail: NSImage?
    @State private var loaded = false
    @FocusState private var removeFocused: Bool
    private var isImage: Bool { item.imageData != nil }
    var body: some View {
        Group {
            if isImage {
                Group {
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
                    else if !loaded { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else { Image(systemName: "photo").font(.ui(size: 24)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(width: 96, height: 96).background(Color.canvas)
                    .clipShape(OpticalRoundedRectangle())
            } else {
                HStack(spacing: 10) {
                    Image(systemName: item.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc").font(.ui(size: 22)).foregroundStyle(Color.muted)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name).font(.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                        if let bytes = item.byteCount { Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).font(.ui(size: 10)).foregroundStyle(Color.muted) }
                    }.frame(width: 135, alignment: .leading)
                }.padding(12).padding(.trailing, 12).frame(height: 62).background(Color.canvas, in: OpticalRoundedRectangle())
            }
        }.overlay(alignment: .topTrailing) {
            Button(action: remove) { Image(systemName: "xmark").font(.ui(size: 9, weight: .bold)).foregroundStyle(.white).frame(width: 20, height: 20).background(.black.opacity(0.8), in: Circle()).padding(3) }
                .buttonStyle(ThumbnailRemoveButtonStyle()).focused($removeFocused)
                .opacity(hovered || removeFocused ? 1 : 0).allowsHitTesting(hovered || removeFocused)
                .padding(3).help("移除\(isImage ? "图片" : "附件")").accessibilityLabel("移除 \(item.name)")
        }.contentShape(OpticalRoundedRectangle()).onHover { hovered = $0 }
            .help(item.name).accessibilityAction(named: Text("移除附件"), remove)
            .task(id: item.id) {
                guard let data = item.imageData else { return }
                let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 288, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                }.value
                guard !Task.isCancelled else { return }
                thumbnail = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }; loaded = true
            }
    }
}

private struct ThumbnailRemoveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Circle()).scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}
