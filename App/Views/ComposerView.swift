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
            leadingWidth: app.searchesTheWeb && webSearchAvailable ? 65 : 31
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
                        .frame(width: 28, height: 28)
                        .modifier(HoverCircle())
                    if app.searchesTheWeb, webSearchAvailable {
                        WebSearchModeButton(turnOff: actions.toggleWebSearch)
                    }
                    if let folder = session.commandFolder {
                        CommandFolderChip(folder: folder, chooseFolder: actions.chooseCommandFolder, turnOff: actions.toggleCommands)
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
        // The + and the last button's glyphs sit 25.5 and 24 from the ends, as in Gemini.
        .padding(.leading, 12)
        .padding(.trailing, 11)
        .onChange(of: textHeight, initial: true) { onTextHeightChange(textHeight) }
    }

    /// Chats with DeepSeek search through its API; commands search through dsh.
    private var webSearchAvailable: Bool {
        session.commandFolder != nil || app.canSearchTheWeb(with: app.currentModel)
    }

    private var trailingControls: some View {
        HStack(spacing: 6) {
            ModelMenu(
                app: app, openSettings: actions.openSettings,
                menuWillOpen: actions.menuWillOpen, menuDidClose: actions.menuDidClose
            )
            if session.isGenerating {
                StopButton(action: actions.escape)
            } else if composer.hasContent {
                CircleIconButton(
                    label: "Send",
                    icon: SendIcon().fill().frame(width: 18, height: 16).offset(x: 1),
                    action: actions.submit
                )
                .frame(width: 28, height: 28)
                .accessibilityIdentifier("send")
            }
            if let expand = actions.expand {
                CircleIconButton.expand(action: expand)
                    .frame(width: 28, height: 28)
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
        let height = Self.rowHeight + ComposerLayout.expandedExtra(textHeight: textHeight)
        return CGSize(width: proposal.width ?? 400, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let plus = subviews[0], field = subviews[1], trailing = subviews[2]
        let trailingSize = trailing.sizeThatFits(.unspecified)
        // The + and the folder chip get what the buttons at the end leave; the chip's name shortens first.
        let leadingRoom = ProposedViewSize(width: max(bounds.width - trailingSize.width - Self.gap * 2, 32), height: nil)
        let plusSize = plus.sizeThatFits(leadingRoom)
        let rowMidY = textHeight > 0
            ? bounds.maxY - Self.rowHeight / 2 + ComposerLayout.expandedRowDrop
            : bounds.minY + Self.rowHeight / 2
        plus.place(at: CGPoint(x: bounds.minX, y: rowMidY), anchor: .leading, proposal: ProposedViewSize(plusSize))
        trailing.place(at: CGPoint(x: bounds.maxX, y: rowMidY), anchor: .trailing, proposal: ProposedViewSize(trailingSize))
        if textHeight > 0 {
            // Above the buttons the text starts where the + glyph does.
            let inset = ComposerTextMetrics.expandedInset
            field.place(
                at: CGPoint(x: bounds.minX + inset, y: bounds.minY + ComposerLayout.textTop),
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
    /// Above the buttons the text starts 17 from the edge, a little left of the + glyph, as in Gemini.
    static let expandedInset: CGFloat = 1
    static let maxLines: CGFloat = 8

    /// Lines are 20 apart, as in Gemini.
    static let lineHeight: CGFloat = 20

    /// With lines fixed at 20 the extra height goes above the glyphs; this raises them back to the
    /// line's middle, level with the + and the buttons.
    static let baselineOffset: CGFloat = 1.5

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    static var oneLineHeight: CGFloat {
        lineHeight.rounded(.up) + verticalInset * 2
    }

    /// The text's height above the buttons, or 0 while it fits on one line next to them.
    /// `leadingWidth` is the + and the mode buttons beside it.
    static func expandedHeight(for text: String, rowWidth: CGFloat, trailingWidth: CGFloat, leadingWidth: CGFloat = 31) -> CGFloat {
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
            attributes: [.font: font, .paragraphStyle: paragraphStyle]
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
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
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
                menu.popUp(beside: sender)
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

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            ModeMenuDelegate.highlight(item, in: menu)
        }

        private static func appIcon(processID: Int32) -> NSImage? {
            guard let icon = NSRunningApplication(processIdentifier: processID)?.icon else { return nil }
            let image = icon.copy() as? NSImage ?? icon
            image.size = NSSize(width: 16, height: 16)
            return image
        }
    }
}

extension NSMenu {
    /// Opens the menu just below the view, or just above it when the screen has no room below, so a bar
    /// near the bottom of the screen never gets a scrolling menu. Returns once the menu closes.
    func popUp(beside view: NSView) {
        let gap: CGFloat = 4
        let height = size.height
        var opensAbove = false
        if let window = view.window, let screen = window.screen {
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            opensAbove = frame.minY - gap - height < screen.visibleFrame.minY
        }
        let top = view.isFlipped ? 0 : view.bounds.height
        let bottom = view.isFlipped ? view.bounds.height : 0
        let y: CGFloat
        if opensAbove {
            // The point is the menu's top-left corner.
            y = view.isFlipped ? top - gap - height : top + gap + height
        } else {
            y = view.isFlipped ? bottom + gap : bottom - gap
        }
        popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
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

/// A choice in a menu, such as Search the Web in the + menu or a model: a check mark at the end of the row
/// when it is on, as Claude's menu shows it.
final class ModeMenuItem: ClosureMenuItem {
    static let menuWidth: CGFloat = 230
    let isOn: Bool
    private let width: CGFloat

    init(title: String, symbol: String?, isOn: Bool, width: CGFloat = ModeMenuItem.menuWidth, handler: @escaping () -> Void) {
        self.isOn = isOn
        self.width = width
        super.init(title: title, symbol: symbol, handler: handler)
        render(highlighted: false)
    }

    /// A menu width that fits the longest title with room for the check mark.
    static func width(fitting titles: [String]) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let longest = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(menuWidth - 40, (longest + 120).rounded(.up))
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func render(highlighted: Bool) {
        let font = NSFont.menuFont(ofSize: 0)
        let color: NSColor = !isEnabled ? .disabledControlTextColor : highlighted ? .selectedMenuItemTextColor : .labelColor
        let text = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        // A mode that can't be used now shows no check mark, as it has no effect.
        if isOn, isEnabled {
            let checkColor: NSColor = highlighted ? .selectedMenuItemTextColor : .controlAccentColor
            let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [checkColor]))
            let check = NSTextAttachment()
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            // A spacer of measured width puts every row's check mark at the same place near the end.
            let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
            let checkWidth = check.image?.size.width ?? 0
            // Menus lay out an attachment by its image's size, so the spacer is a blank image of that width.
            let spacerWidth = max(12, width - 96 - titleWidth - checkWidth)
            let spacer = NSTextAttachment()
            spacer.image = NSImage(size: NSSize(width: spacerWidth, height: 1), flipped: false) { _ in true }
            text.append(NSAttributedString(attachment: spacer))
            text.append(NSAttributedString(attachment: check))
        }
        attributedTitle = text
    }
}

/// Turns a highlighted choice's check mark white with its title.
@MainActor
final class ModeMenuDelegate: NSObject, NSMenuDelegate {
    static func highlight(_ item: NSMenuItem?, in menu: NSMenu) {
        for case let mode as ModeMenuItem in menu.items {
            mode.render(highlighted: mode === item)
        }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        Self.highlight(item, in: menu)
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
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color(nsColor: .controlAccentColor).opacity(0.13)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Search the Web"))
        .accessibilityLabel(Text("Search the Web"))
        .accessibilityIdentifier("webSearchMode")
    }
}
