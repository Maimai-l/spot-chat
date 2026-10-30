import AppKit
import SwiftUI
import SpotCore

/// Frosted background that stays frosted while the window is not key.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Press and drag on empty areas of a window to move it.
/// A movement shorter than `threshold` points stays a click.
struct WindowDragArea: NSViewRepresentable {
    var threshold: CGFloat = 3
    var onDragEnd: () -> Void = {}

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.threshold = threshold
        view.onDragEnd = onDragEnd
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.threshold = threshold
        view.onDragEnd = onDragEnd
    }

    final class DragView: NSView {
        var threshold: CGFloat = 3
        var onDragEnd: () -> Void = {}
        private var tracker: DragTracker?
        private var startOrigin: NSPoint = .zero

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            tracker = DragTracker(start: NSEvent.mouseLocation, threshold: threshold)
            startOrigin = window?.frame.origin ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            guard var current = tracker, let window else { return }
            if let offset = current.update(to: NSEvent.mouseLocation) {
                window.setFrameOrigin(NSPoint(x: startOrigin.x + offset.width, y: startOrigin.y + offset.height))
            }
            tracker = current
        }

        override func mouseUp(with event: NSEvent) {
            if tracker?.isDragging == true {
                onDragEnd()
            }
            tracker = nil
        }
    }
}

/// Multi-line input. Enter sends, Shift+Enter inserts a line break,
/// and Enter while an input method is composing commits the composition instead of sending.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusRequest: Int
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onPasteFiles: ([URL]) -> Void = { _ in }
    var onPasteImage: (Data) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let contentSize = scrollView.contentSize
        let textView = ComposerTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.font = .systemFont(ofSize: 16)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.placeholder = placeholder
        textView.string = text
        textView.onPasteFiles = onPasteFiles
        textView.onPasteImage = onPasteImage
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("composer")

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        textView.placeholder = placeholder
        textView.onPasteFiles = onPasteFiles
        textView.onPasteImage = onPasteImage
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                guard let window = textView.window else { return }
                window.makeFirstResponder(textView)
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var textView: ComposerTextView?
        var lastFocusRequest = -1

        init(parent: ComposerField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    var placeholder = "" {
        didSet {
            if placeholder != oldValue { needsDisplay = true }
        }
    }
    var onPasteFiles: ([URL]) -> Void = { _ in }
    var onPasteImage: (Data) -> Void = { _ in }

    /// Pasted files and images become attachments; text is pasted as plain text.
    override func paste(_ sender: Any?) {
        if takeAttachments(from: .general) { return }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if takeAttachments(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func takeAttachments(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onPasteFiles(urls)
            return true
        }
        guard pasteboard.string(forType: .string) == nil else { return false }
        if let png = pasteboard.data(forType: .png) {
            onPasteImage(png)
            return true
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            onPasteImage(png)
            return true
        }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(
            x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerOrigin.y
        )
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
