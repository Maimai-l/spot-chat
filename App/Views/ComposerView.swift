import AppKit
import SwiftUI
import SpotCore

/// What the input area can ask its window to do.
struct ComposerActions {
    var submit: () -> Void
    var escape: () -> Void
    var openSettings: () -> Void
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
    /// Turns web search on or off.
    var toggleWebSearch: () -> Void = {}
    /// Turns running commands on, in the default folder, or off.
    var toggleCommands: () -> Void = {}
    var chooseCommandFolder: () -> Void = {}
    /// Picks files and folders to point to by path.
    var addPaths: () -> Void = {}
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
        let measured = ComposerTextMetrics.expandedHeight(
            for: composer.draft,
            rowWidth: width,
            trailingWidth: trailingWidth,
            leadingWidth: app.searchesTheWeb && webSearchAvailable ? 73 : 35
        )
        // The folder chip takes the row's space, so the text sits above the buttons.
        let textHeight = session.commandFolder != nil ? max(measured, ComposerTextMetrics.oneLineHeight) : measured
        VStack(alignment: .leading, spacing: ComposerLayout.rowSpacing) {
            if !composer.attachments.isEmpty || !composer.paths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(composer.paths, id: \.self) { path in
                            PathTile(url: path) {
                                composer.remove(path: path)
                            }
                        }
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
                HStack(spacing: 6) {
                    PlusMenuButton(
                        actions: actions, commandsOn: session.commandFolder != nil,
                        webSearchOn: app.searchesTheWeb, webSearchAvailable: webSearchAvailable
                    )
                        .frame(width: 32, height: 32)
                        .modifier(HoverCircle())
                    if app.searchesTheWeb, webSearchAvailable {
                        WebSearchModeButton(turnOff: actions.toggleWebSearch)
                    }
                    if let folder = session.commandFolder {
                        CommandFolderChip(folder: folder, chooseFolder: actions.chooseCommandFolder, turnOff: actions.toggleCommands)
                            .offset(y: -ComposerLayout.trailingLift)
                    }
                }
                ComposerField(
                    text: $composer.draft,
                    placeholder: String(localized: "Ask Spot"),
                    focusRequest: composer.focusRequest,
                    onSubmit: actions.submit,
                    onEscape: actions.escape,
                    onPasteFiles: { composer.add(fileURLs: $0, asPaths: session.commandFolder != nil) },
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

    /// Chats with DeepSeek search through its API; commands search through dsh.
    private var webSearchAvailable: Bool {
        session.commandFolder != nil || app.canSearchTheWeb(with: app.currentModel)
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
        let trailingSize = trailing.sizeThatFits(.unspecified)
        // The + and the folder chip get what the buttons at the end leave; the chip's name shortens first.
        let leadingRoom = ProposedViewSize(width: max(bounds.width - trailingSize.width - Self.gap * 2, 32), height: nil)
        let plusSize = plus.sizeThatFits(leadingRoom)
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

    static var oneLineHeight: CGFloat {
        lineHeight.rounded(.up) + verticalInset * 2
    }

    /// The text's height above the buttons, or 0 while it fits on one line next to them.
    /// `leadingWidth` is the + and the mode buttons beside it.
    static func expandedHeight(for text: String, rowWidth: CGFloat, trailingWidth: CGFloat, leadingWidth: CGFloat = 35) -> CGFloat {
        guard rowWidth > 0, !text.isEmpty else { return 0 }
        let rowTextWidth = rowWidth - leadingWidth - ComposerRowLayout.gap - 3 - trailingWidth - ComposerRowLayout.gap - linePadding * 2
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
    var commandsOn = false
    var webSearchOn = false
    var webSearchAvailable = false

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    func makeNSView(context: Context) -> NSButton {
        let label = String(localized: "Add")
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
        context.coordinator.commandsOn = commandsOn
        context.coordinator.webSearchOn = webSearchOn
        context.coordinator.webSearchAvailable = webSearchAvailable
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var actions: ComposerActions
        var commandsOn = false
        var webSearchOn = false
        var webSearchAvailable = false

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
            menu.delegate = self
            menu.minimumWidth = ModeMenuItem.menuWidth
            let modes = [
                ModeMenuItem(
                    title: String(localized: "Search the Web"), symbol: "globe", isOn: webSearchOn,
                    handler: actions.toggleWebSearch
                ),
                ModeMenuItem(
                    title: String(localized: "Run Commands"), symbol: "apple.terminal", isOn: commandsOn,
                    handler: actions.toggleCommands
                ),
            ]
            modes[0].isEnabled = webSearchAvailable
            modes[0].render(highlighted: false)
            if commandsOn {
                // dsh reads files where they are, so they go in by path.
                menu.addItem(ClosureMenuItem(title: String(localized: "Add File Path…"), symbol: "paperclip", handler: actions.addPaths))
                menu.addItem(.separator())
                modes.forEach(menu.addItem)
                return menu
            }
            // One picker takes images and files alike.
            menu.addItem(ClosureMenuItem(title: String(localized: "Upload Image or File…"), symbol: "paperclip", handler: actions.uploadFiles))
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
            menu.addItem(.separator())
            modes.forEach(menu.addItem)
            return menu
        }

        /// The check mark of a highlighted mode turns white with its title.
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            for case let mode as ModeMenuItem in menu.items {
                mode.render(highlighted: mode === item)
            }
        }

        private static func appIcon(processID: Int32) -> NSImage? {
            guard let icon = NSRunningApplication(processIdentifier: processID)?.icon else { return nil }
            let image = icon.copy() as? NSImage ?? icon
            image.size = NSSize(width: 16, height: 16)
            return image
        }
    }
}

class ClosureMenuItem: NSMenuItem {
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

/// A mode in the + menu, such as Search the Web: a check mark at the end of the row when it is on,
/// as Claude's menu shows it.
final class ModeMenuItem: ClosureMenuItem {
    static let menuWidth: CGFloat = 230
    let isOn: Bool

    init(title: String, symbol: String, isOn: Bool, handler: @escaping () -> Void) {
        self.isOn = isOn
        super.init(title: title, symbol: symbol, handler: handler)
        render(highlighted: false)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func render(highlighted: Bool) {
        let font = NSFont.menuFont(ofSize: 0)
        let style = NSMutableParagraphStyle()
        // Past the title, at the end of the row where a submenu's arrow sits.
        style.tabStops = [NSTextTab(textAlignment: .right, location: Self.menuWidth - 62)]
        let color: NSColor = !isEnabled ? .disabledControlTextColor : highlighted ? .selectedMenuItemTextColor : .labelColor
        let text = NSMutableAttributedString(
            string: title, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: color]
        )
        if isOn {
            let checkColor: NSColor = !isEnabled ? .disabledControlTextColor : highlighted ? .selectedMenuItemTextColor : .controlAccentColor
            let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [checkColor]))
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            text.append(NSAttributedString(string: "\t", attributes: [.font: font, .paragraphStyle: style]))
            text.append(NSAttributedString(attachment: attachment))
        }
        attributedTitle = text
    }
}

/// The globe beside the + while web search is on, round like the + itself. Clicking it turns it off.
struct WebSearchModeButton: View {
    let turnOff: () -> Void

    var body: some View {
        Button(action: turnOff) {
            Image(systemName: "globe")
                .font(.system(size: 15))
                .foregroundStyle(Color(nsColor: .controlAccentColor))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(nsColor: .controlAccentColor).opacity(0.13)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(y: -ComposerLayout.trailingLift)
        .help(Text("Search the Web"))
        .accessibilityLabel(Text("Search the Web"))
        .accessibilityIdentifier("webSearchMode")
    }
}
