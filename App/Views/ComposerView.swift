import AppKit
import SwiftUI
import SpotCore

/// What the input area can ask its window to do.
struct ComposerActions {
    var submit: () -> Void
    var escape: () -> Void
    var openSettings: () -> Void
    var uploadImages: () -> Void
    var uploadFiles: () -> Void
    var shareWindow: (SharableWindow) -> Void
    var showPermissionGuide: () -> Void
    /// The windows that can be shared, or nil without screen recording permission.
    var loadWindows: () async -> [SharableWindow]?
    /// Called around the + menu so the capsule does not hide while it is open.
    var menuWillOpen: () -> Void
    var menuDidClose: () -> Void
    /// Shown as the last button in the capsule.
    var expand: (() -> Void)? = nil
}

/// The input shared by the mini window and the full window:
/// attachments above, the text with + and the model in the middle, the sharing tag below.
/// Text that no longer fits on one line moves above the buttons, and the input grows with it.
struct ComposerView: View {
    @ObservedObject var composer: ComposerModel
    @ObservedObject var session: ChatSession
    @ObservedObject var app: AppModel
    let actions: ComposerActions
    /// Reports the height of the text above the buttons, or 0 while the text fits next to them.
    var onTextHeightChange: (CGFloat) -> Void = { _ in }

    @State private var width: CGFloat = 0
    @State private var trailingWidth: CGFloat = 120

    var body: some View {
        let textHeight = ComposerTextMetrics.expandedHeight(
            for: composer.draft,
            rowWidth: width,
            trailingWidth: trailingWidth
        )
        VStack(alignment: .leading, spacing: ComposerLayout.rowSpacing) {
            if !composer.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(composer.attachments) { attachment in
                            AttachmentTile(attachment: attachment) {
                                composer.remove(attachment)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                }
                .frame(height: ComposerLayout.attachmentsRowHeight)
            }
            ComposerRowLayout(textHeight: textHeight) {
                PlusMenuButton(actions: actions)
                    .frame(width: 32, height: 32)
                    .modifier(HoverCircle())
                ComposerField(
                    text: $composer.draft,
                    placeholder: String(localized: "Ask Spot"),
                    focusRequest: composer.focusRequest,
                    onSubmit: actions.submit,
                    onEscape: actions.escape,
                    onPasteFiles: { composer.add(fileURLs: $0) },
                    onPasteImage: { composer.add(imageData: $0, fileName: String(localized: "Pasted Image") + ".png") }
                )
                trailingControls
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { trailingWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
            if let shared = composer.sharedWindow {
                ShareTag(window: shared) {
                    composer.sharedWindow = nil
                }
                .frame(height: ComposerLayout.tagRowHeight)
            }
            if let notice = composer.notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: ComposerLayout.noticeRowHeight)
                    .padding(.leading, 8)
                    .accessibilityIdentifier("composerNotice")
            }
        }
        .padding(.vertical, 8)
        // Puts the centers of the + and of the last button half the bar's height from its ends, as Gemini does.
        .padding(.horizontal, 12)
        .onChange(of: textHeight, initial: true) { onTextHeightChange(textHeight) }
    }

    private var trailingControls: some View {
        HStack(spacing: 6) {
            ModelMenu(app: app, openSettings: actions.openSettings)
                .offset(y: -ComposerLayout.trailingLift)
            EffortMenu(app: app)
                .offset(y: -ComposerLayout.trailingLift)
            if session.isGenerating {
                StopButton(action: actions.escape)
            } else if composer.hasContent {
                CircleIconButton(
                    label: "Send",
                    icon: SendIcon().fill().frame(width: 18, height: 16).offset(x: 1),
                    action: actions.submit
                )
                .frame(width: 32, height: 32)
                .offset(y: -ComposerLayout.trailingLift)
                .accessibilityIdentifier("send")
            }
            if let expand = actions.expand {
                CircleIconButton.expand(action: expand)
                    .frame(width: 32, height: 32)
                    .offset(y: -ComposerLayout.trailingLift)
            }
        }
        .fixedSize()
    }
}

/// Places the +, the text and the buttons on one row, or the text above a row of buttons once it needs
/// more than a line. The same three views are moved rather than rebuilt, so typing and input methods are
/// never interrupted.
struct ComposerRowLayout: Layout {
    /// 0 keeps everything on one row.
    var textHeight: CGFloat

    static let rowHeight = ComposerLayout.baseHeight - 16
    static let fieldHeight: CGFloat = 28
    static let gap: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = textHeight > 0 ? textHeight + ComposerLayout.rowSpacing + Self.rowHeight : Self.rowHeight
        return CGSize(width: proposal.width ?? 400, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let plus = subviews[0], field = subviews[1], trailing = subviews[2]
        let plusSize = plus.sizeThatFits(.unspecified)
        let trailingSize = trailing.sizeThatFits(.unspecified)
        let rowMidY = (textHeight > 0 ? bounds.maxY - Self.rowHeight : bounds.minY) + Self.rowHeight / 2
        plus.place(at: CGPoint(x: bounds.minX, y: rowMidY), anchor: .leading, proposal: ProposedViewSize(plusSize))
        trailing.place(at: CGPoint(x: bounds.maxX, y: rowMidY), anchor: .trailing, proposal: ProposedViewSize(trailingSize))
        if textHeight > 0 {
            // Above the buttons the text starts where the + glyph does.
            let inset = ComposerTextMetrics.expandedInset
            field.place(
                at: CGPoint(x: bounds.minX + inset, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width - inset * 2, height: textHeight)
            )
        } else {
            let x = bounds.minX + plusSize.width + Self.gap + 3
            let width = max(bounds.maxX - trailingSize.width - Self.gap - x, 40)
            field.place(at: CGPoint(x: x, y: rowMidY), anchor: .leading, proposal: ProposedViewSize(width: width, height: Self.fieldHeight))
        }
    }
}

/// Works out when the text no longer fits on the row and how tall it is above the buttons.
enum ComposerTextMetrics {
    static let font = NSFont.systemFont(ofSize: 16)
    /// The text view's line fragment padding on each side.
    static let linePadding: CGFloat = 4
    /// The text view's inset above and below the text.
    static let verticalInset: CGFloat = 4
    static let expandedInset: CGFloat = 4
    static let maxLines: CGFloat = 8

    static var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    /// The text's height above the buttons, or 0 while it fits on one line next to them.
    static func expandedHeight(for text: String, rowWidth: CGFloat, trailingWidth: CGFloat) -> CGFloat {
        guard rowWidth > 0, !text.isEmpty else { return 0 }
        let rowTextWidth = rowWidth - 35 - ComposerRowLayout.gap - 3 - trailingWidth - ComposerRowLayout.gap - linePadding * 2
        let fitsOnRow = !text.contains("\n") && width(of: text) <= rowTextWidth
        guard !fitsOnRow else { return 0 }
        let textWidth = rowWidth - expandedInset * 2 - linePadding * 2
        let lines = min(max(height(of: text, width: textWidth) / lineHeight, 1), maxLines)
        return (lines * lineHeight).rounded(.up) + verticalInset * 2
    }

    static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func height(of text: String, width: CGFloat) -> CGFloat {
        // A trailing line break starts a new, still empty line.
        let measured = text.hasSuffix("\n") ? text + " " : text
        let rect = (measured as NSString).boundingRect(
            with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }
}

/// The filled paper plane used for sending.
struct SendIcon: Shape {
    /// Gemini's send arrow: straight left edges, a notch reaching almost halfway in, softly rounded outer
    /// corners and a nearly sharp notch. Each corner is (x, y, radius), relative to the height.
    private static let corners: [(CGFloat, CGFloat, CGFloat)] = [
        (0, 0, 0.05), (1, 0.5, 0.05), (0, 1, 0.05), (0, 0.635, 0.01), (0.46, 0.5, 0.02), (0, 0.365, 0.01),
    ]

    func path(in rect: CGRect) -> Path {
        let points = Self.corners.map { CGPoint(x: rect.minX + $0.0 * rect.width, y: rect.minY + $0.1 * rect.height) }
        let last = points[points.count - 1]
        var path = Path()
        path.move(to: CGPoint(x: (last.x + points[0].x) / 2, y: (last.y + points[0].y) / 2))
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            path.addArc(tangent1End: points[index], tangent2End: next, radius: Self.corners[index].2 * rect.height)
        }
        path.closeSubpath()
        return path
    }
}

/// "Sharing App › Window ×" below the input.
struct ShareTag: View {
    let window: SharableWindow
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 12))
            Text("Sharing \(window.label)")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Stop Sharing"))
            .accessibilityIdentifier("stopSharing")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.leading, 38)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shareTag")
    }
}

/// The + button. Its native menu offers uploads and the windows that can be shared.
struct PlusMenuButton: NSViewRepresentable {
    let actions: ComposerActions

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    func makeNSView(context: Context) -> NSButton {
        let label = String(localized: "Add Attachment or Share Window")
        let button = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: label) ?? NSImage(),
            target: context.coordinator,
            action: #selector(Coordinator.open(_:))
        )
        button.isBordered = false
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        button.contentTintColor = .labelColor
        button.toolTip = label
        button.setAccessibilityIdentifier("plusMenu")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.actions = actions
    }

    @MainActor
    final class Coordinator: NSObject {
        var actions: ComposerActions

        init(actions: ComposerActions) {
            self.actions = actions
        }

        @objc func open(_ sender: NSButton) {
            actions.menuWillOpen()
            Task { @MainActor in
                let windows = await actions.loadWindows()
                let menu = makeMenu(windows: windows)
                let point = NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.height + 4 : -4)
                menu.popUp(positioning: nil, at: point, in: sender)
                actions.menuDidClose()
            }
        }

        private func makeMenu(windows: [SharableWindow]?) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(ClosureMenuItem(title: String(localized: "Upload Image…"), symbol: "photo", handler: actions.uploadImages))
            menu.addItem(ClosureMenuItem(title: String(localized: "Upload File…"), symbol: "paperclip", handler: actions.uploadFiles))
            menu.addItem(.separator())
            let share = String(localized: "Share Window")
            if let windows {
                let item = NSMenuItem(title: share, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
                let submenu = NSMenu(title: share)
                if windows.isEmpty {
                    let empty = NSMenuItem(title: String(localized: "No Windows"), action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    submenu.addItem(empty)
                }
                for window in windows {
                    let entry = ClosureMenuItem(title: window.label, symbol: nil) { [actions] in actions.shareWindow(window) }
                    entry.image = Self.appIcon(processID: window.processID)
                    submenu.addItem(entry)
                }
                item.submenu = submenu
                menu.addItem(item)
            } else {
                menu.addItem(ClosureMenuItem(title: share, symbol: "macwindow.on.rectangle", handler: actions.showPermissionGuide))
            }
            return menu
        }

        private static func appIcon(processID: Int32) -> NSImage? {
            guard let icon = NSRunningApplication(processIdentifier: processID)?.icon else { return nil }
            let image = icon.copy() as? NSImage ?? icon
            image.size = NSSize(width: 16, height: 16)
            return image
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String?, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}
