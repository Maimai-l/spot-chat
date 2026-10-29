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
struct ComposerView: View {
    @ObservedObject var composer: ComposerModel
    @ObservedObject var session: ChatSession
    @ObservedObject var app: AppModel
    let actions: ComposerActions

    var body: some View {
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
            HStack(spacing: 6) {
                PlusMenuButton(actions: actions)
                    .frame(width: 32, height: 32)
                    .modifier(HoverCircle())
                    .padding(.trailing, 3)
                ComposerField(
                    text: $composer.draft,
                    placeholder: String(localized: "Ask Spot"),
                    focusRequest: composer.focusRequest,
                    onSubmit: actions.submit,
                    onEscape: actions.escape,
                    onPasteFiles: { composer.add(fileURLs: $0) },
                    onPasteImage: { composer.add(imageData: $0, fileName: String(localized: "Pasted Image") + ".png") }
                )
                .frame(height: 28)
                ModelMenu(app: app, openSettings: actions.openSettings)
                    .offset(y: -ComposerLayout.trailingLift)
                    // As far from the edge, or from the button after it, as the + glyph is from the start.
                    .padding(.trailing, 10)
                if session.isGenerating {
                    StopButton(action: actions.escape)
                }
                if let expand = actions.expand {
                    CircleIconButton.expand(action: expand)
                        .frame(width: 32, height: 32)
                        .offset(y: -ComposerLayout.trailingLift)
                }
            }
            .frame(height: ComposerLayout.baseHeight - 16)
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
