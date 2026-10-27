import AppKit
import SwiftUI

struct ComposerEditor: NSViewRepresentable {
    static let minimumHeight: CGFloat = 42
    static let maximumHeight: CGFloat = 176
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var onSend: () -> Void
    var onFiles: ([URL], Bool) -> Void
    var onFocusChange: (Bool) -> Void = { _ in }
    var onCommandKey: (UInt16) -> Bool = { _ in false }
    var focusRequest = 0
    var textScale = VisualPreferences.shared.textScale
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        let view = MessageTextView(frame: NSRect(x: 0, y: 0, width: 400, height: Self.minimumHeight))
        view.isRichText = false; view.drawsBackground = false; view.isAutomaticQuoteSubstitutionEnabled = false
        view.font = NSFont.systemFont(ofSize: 15 * textScale); view.textColor = BotsPalette.ink; view.insertionPointColor = BotsPalette.ink
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.minSize = NSSize(width: 0, height: Self.minimumHeight)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 0, height: 12)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]; view.delegate = context.coordinator
        view.onLayout = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.scheduleResize(view) }
        }
        scroll.documentView = view
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MessageTextView else { return }
        context.coordinator.parent = self
        scroll.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        view.font = NSFont.systemFont(ofSize: 15 * textScale)
        view.textColor = BotsPalette.ink; view.insertionPointColor = BotsPalette.ink
        if view.string != text && !view.hasMarkedText() { view.string = text }
        view.isEditable = enabled
        view.onSend = onSend; view.onFiles = onFiles; view.onFocusChange = onFocusChange
        view.onCommandKey = onCommandKey; view.placeholder = placeholder
        view.setAccessibilityLabel(placeholder)
        view.needsDisplay = true
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isEditable else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        context.coordinator.scheduleResize(view)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        private var scheduled = false
        var lastFocusRequest = 0
        init(_ parent: ComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? MessageTextView else { return }
            parent.text = view.string; view.needsDisplay = true; scheduleResize(view)
        }
        func scheduleResize(_ view: NSTextView) {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.scheduled = false
                guard let view, let scroll = view.enclosingScrollView, scroll.contentSize.width > 0,
                      let container = view.textContainer, let layout = view.layoutManager else { return }
                let width = scroll.contentSize.width
                if abs(view.frame.width - width) > 0.5 { view.setFrameSize(NSSize(width: width, height: view.frame.height)) }
                container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                layout.ensureLayout(for: container)
                // The extra fragment accounts for a trailing Return and empty last line.
                let textHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
                let contentHeight = ceil(textHeight + view.textContainerInset.height * 2)
                let measured = min(ComposerEditor.maximumHeight, max(ComposerEditor.minimumHeight, contentHeight))
                scroll.hasVerticalScroller = contentHeight > ComposerEditor.maximumHeight
                let documentHeight = max(contentHeight, measured)
                if abs(view.frame.height - documentHeight) > 0.5 { view.setFrameSize(NSSize(width: width, height: documentHeight)) }
                if abs(self.parent.height - measured) > 0.5 { self.parent.height = measured }
            }
        }
    }
}

final class MessageTextView: NSTextView {
    var onSend: (() -> Void)?
    var onFiles: (([URL], Bool) -> Void)?
    var placeholder = ""
    var onFocusChange: ((Bool) -> Void)?
    var onLayout: (() -> Void)?
    var onCommandKey: ((UInt16) -> Bool)?
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { onLayout?() }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { self.onFocusChange?(true) } }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { DispatchQueue.main.async { self.onFocusChange?(false) } }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           onCommandKey?(event.keyCode) == true { return }
        if [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option), !hasMarkedText() { onSend?(); return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !hasMarkedText() {
            (placeholder as NSString).draw(at: NSPoint(x: 5, y: 12), withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13.5), .foregroundColor: BotsPalette.muted])
        }
    }
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty { onFiles?(files, false); return }
        if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BotClient-Attachments", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("图片-\(UUID().uuidString.prefix(8)).png")
                try data.write(to: url, options: .atomic); onFiles?([url], true); return
            } catch { NSSound.beep(); return }
        }
        super.paste(sender)
    }
}
