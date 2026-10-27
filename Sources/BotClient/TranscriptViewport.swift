import SwiftUI
import AppKit
import Observation

/// Observe the actual macOS list scroll view, rather than relying on lazy-stack targets.
/// One observer per transcript; recycled row probes only reconnect the same instance.
@Observable @MainActor final class TranscriptViewport {
    private(set) var userScrolling = false
    private(set) var atBottom = true
    var followsBottom = true
    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pinScheduled = false
    @ObservationIgnored private var geometryScheduled = false
    @ObservationIgnored private var enabled = true
    @ObservationIgnored private weak var candidate: NSView?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var liveScrolling = false
    @ObservationIgnored private var inputActive = false
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var eventMonitor: Any?

    func attach(from view: NSView) {
        candidate = view
        guard enabled, let scroll = view.enclosingScrollView, scroll !== scrollView else { return }
        detach()
        scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleGeometryRead() }
        })
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.liveScrolling = true; self?.updateScrollingState(); self?.readGeometry()
            }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readGeometry(); self?.liveScrolling = false; self?.updateScrollingState()
            }
        })
        if let document = scroll.documentView {
            document.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePin() }
            })
        }
        // Legacy mouse wheels and Page Up/Down don't always have gesture phases.
        // Observe only this transcript's input and return the original event untouched.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self, weak scroll] event in
            MainActor.assumeIsolated {
                if let self, let scroll, event.window === scroll.window, !scroll.isHiddenOrHasHiddenAncestor {
                    let wheelHere = event.type == .scrollWheel && scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
                    let responder = scroll.window?.firstResponder as? NSView
                    let keyboardHere = event.type == .keyDown && [115, 116, 119, 121, 125, 126, 49].contains(event.keyCode)
                        && (responder === scroll || responder?.isDescendant(of: scroll) == true)
                    if wheelHere || keyboardHere { self.markUserInput() }
                }
            }
            return event
        }
        readGeometry()
        schedulePin()
    }

    private func updateScrollingState() { userScrolling = liveScrolling || inputActive }
    private func markUserInput() {
        inputTask?.cancel()
        inputActive = true; updateScrollingState(); readGeometry()
        let token = generation
        inputTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.readGeometry(); self.inputActive = false; self.inputTask = nil; self.updateScrollingState()
        }
    }

    private func scheduleGeometryRead() {
        guard !geometryScheduled else { return }
        geometryScheduled = true
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.geometryScheduled = false; self.readGeometry()
        }
    }

    func activate() {
        enabled = true
        if let candidate, candidate.window != nil { attach(from: candidate) }
    }
    func stop() { enabled = false; detach() }

    private func readGeometry() {
        guard let scroll = scrollView, let document = scroll.documentView else { return }
        let visible = scroll.contentView.bounds
        atBottom = document.isFlipped
            ? visible.maxY >= document.bounds.maxY - 100
            : visible.minY <= document.bounds.minY + 100
        if userScrolling { followsBottom = atBottom }
    }

    private func schedulePin() {
        guard followsBottom, !userScrolling, !pinScheduled else { return }
        pinScheduled = true
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.pinScheduled = false
            guard self.followsBottom, !self.userScrolling else { return }
            self.scrollToBottom()
        }
    }

    @discardableResult func scrollToBottom() -> Bool {
        guard let scroll = scrollView, let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height) : document.bounds.minY
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
        readGeometry()
        return true
    }

    func detach() {
        generation += 1; pinScheduled = false; geometryScheduled = false
        inputTask?.cancel(); inputTask = nil; liveScrolling = false; inputActive = false
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []; scrollView = nil; userScrolling = false
    }
    deinit {
        inputTask?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

struct TranscriptViewportProbe: NSViewRepresentable {
    let viewport: TranscriptViewport
    func makeNSView(context: Context) -> Probe {
        let view = Probe(); view.viewport = viewport; return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.viewport = viewport; view.connect()
    }
    final class Probe: NSView {
        weak var viewport: TranscriptViewport?
        private var connectionScheduled = false
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        func connect() {
            guard !connectionScheduled else { return }
            connectionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.connectionScheduled = false
                guard self.window != nil else { return }
                self.viewport?.attach(from: self)
            }
        }
    }
}
