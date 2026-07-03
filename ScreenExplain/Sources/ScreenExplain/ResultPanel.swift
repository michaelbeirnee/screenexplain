import AppKit

final class ResultPanel: NSPanel {
    private let textView = NSTextView()
    private let scrollView = NSScrollView()

    static var shared: ResultPanel?

    convenience init() {
        let size = NSSize(width: 460, height: 360)
        self.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Explain"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        scrollView.frame = NSRect(origin: .zero, size: size)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.string = "Thinking…"
        textView.drawsBackground = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        contentView = scrollView
    }

    var currentText: String {
        textView.string
    }

    func resetText() {
        textView.string = ""
    }

    func append(_ text: String) {
        textView.string += text
        textView.scrollToEndOfDocument(nil)
    }

    func showNear(point: NSPoint) {
        var origin = NSPoint(x: point.x, y: point.y - frame.height)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        }
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
    }
}
