import AppKit

/// A display plus a rectangle local to it (top-left origin, in points —
/// matching ScreenCaptureKit's coordinate space) picked via drag-selection.
struct SelectedRegion {
    let displayID: CGDirectDisplayID
    let rect: CGRect
}

enum RegionSelector {
    /// Shows a dimming overlay spanning every monitor so the user can drag
    /// out a rectangle, screenshot-tool style, to say which screen (and which
    /// part of it) active mode should watch. Calls completion with the chosen
    /// display + rect, or nil if cancelled (Escape) or the drag was too small
    /// to count as an intentional selection.
    static func choose(completion: @escaping (SelectedRegion?) -> Void) {
        let overlay = SelectionOverlayWindow(completion: completion)
        overlay.begin()
    }
}

private final class SelectionOverlayWindow: NSWindow {
    private let completion: (SelectedRegion?) -> Void
    private var didFinish = false

    init(completion: @escaping (SelectedRegion?) -> Void) {
        self.completion = completion
        let unionFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }

        super.init(contentRect: unionFrame, styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let view = SelectionView(frame: NSRect(origin: .zero, size: unionFrame.size))
        contentView = view
        view.onFinish = { [weak self] rect in self?.finish(windowLocalRect: rect) }
        view.onCancel = { [weak self] in self?.finish(windowLocalRect: nil) }
    }

    override var canBecomeKey: Bool { true }

    func begin() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private func finish(windowLocalRect: CGRect?) {
        guard !didFinish else { return }
        didFinish = true
        orderOut(nil)

        guard let windowLocalRect, windowLocalRect.width > 4, windowLocalRect.height > 4 else {
            completion(nil)
            return
        }

        let globalCocoaRect = CGRect(
            x: frame.origin.x + windowLocalRect.origin.x,
            y: frame.origin.y + windowLocalRect.origin.y,
            width: windowLocalRect.width,
            height: windowLocalRect.height
        )
        completion(Self.convert(globalCocoaRect: globalCocoaRect))
    }

    /// Cocoa screen coordinates are per-desktop, origin bottom-left, Y up.
    /// ScreenCaptureKit wants a rect local to one display, origin top-left,
    /// Y down — so find which display the selection landed on and flip into
    /// its local space.
    private static func convert(globalCocoaRect: CGRect) -> SelectedRegion? {
        let screen = NSScreen.screens.max { a, b in
            a.frame.intersection(globalCocoaRect).sizeArea < b.frame.intersection(globalCocoaRect).sizeArea
        }
        guard let screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        let screenFrame = screen.frame
        let clamped = globalCocoaRect.intersection(screenFrame)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }

        let localCocoaX = clamped.origin.x - screenFrame.origin.x
        let localCocoaY = clamped.origin.y - screenFrame.origin.y
        let localQuartzY = screenFrame.height - localCocoaY - clamped.height
        let localRect = CGRect(x: localCocoaX, y: localQuartzY, width: clamped.width, height: clamped.height)

        return SelectedRegion(displayID: displayID, rect: localRect)
    }
}

private extension CGRect {
    var sizeArea: CGFloat { isNull ? 0 : width * height }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentRect: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentRect = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onFinish?(currentRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        guard currentRect.width > 0, currentRect.height > 0 else { return }

        currentRect.fill(using: .clear)
        NSColor.white.setStroke()
        NSBezierPath(rect: currentRect).stroke()
    }
}
