import SwiftUI
import AppKit
import SpotCore

/// The input shared by the mini window and the full window: the draft, the attachments waiting to be sent
/// and the window being shared. Draft and attachments are saved on every change so nothing typed is lost.
@MainActor
final class ComposerModel: ObservableObject {
    static let maxTextFileSize = 2_000_000

    @Published var draft: String {
        didSet {
            if draft != oldValue { draftStorage.saveDraft(draft) }
        }
    }
    @Published private(set) var attachments: [Attachment] {
        didSet { saveAttachmentIDs() }
    }
    /// Files and folders for running commands: only their paths are sent.
    @Published private(set) var paths: [URL] {
        didSet { defaults.set(paths.map(\.path), forKey: Self.pathsKey) }
    }
    /// Captured again each time a message is sent, so follow-up questions see the window as it is.
    @Published var sharedWindow: SharableWindow?
    @Published private(set) var focusRequest = 0
    /// A short message about something that could not be attached.
    @Published private(set) var notice: String?
    /// Text selected in another app, shown as a strip at the top of the input and sent quoted before the
    /// question.
    @Published var selection: String? {
        didSet {
            if selection != oldValue { selectionOpen = false }
        }
    }
    /// Whether the selection's strip shows all of it rather than one line.
    @Published var selectionOpen = false
    /// Whether the input says, in a strip at its top, that bringing selected text needs Accessibility access.
    @Published var asksForAccessibility = false

    private let app: AppModel
    private let draftStorage: DraftStorage
    private let defaults: UserDefaults
    private var noticeTimer: DispatchWorkItem?
    private static let attachmentsKey = "SpotChat.pendingAttachments"
    static let pathsKey = "SpotChat.pendingPaths"

    init(app: AppModel, draftStorage: DraftStorage, defaults: UserDefaults = .standard) {
        self.app = app
        self.draftStorage = draftStorage
        self.defaults = defaults
        self.draft = draftStorage.loadDraft()
        let ids = (defaults.stringArray(forKey: Self.attachmentsKey) ?? []).compactMap(UUID.init(uuidString:))
        self.attachments = (try? app.fileService.attachments(withIDs: ids)) ?? []
        self.paths = (defaults.stringArray(forKey: Self.pathsKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasExtras
    }

    var hasExtras: Bool {
        !attachments.isEmpty || !paths.isEmpty || sharedWindow != nil || selection != nil
    }

    /// The text to send: the selection quoted, then the draft.
    var messageText: String {
        SelectionQuote.message(quoting: selection, question: draft)
    }

    /// Empties the draft and the selection once they are sent.
    func clearSent() {
        draft = ""
        selection = nil
    }

    func requestFocus() {
        focusRequest += 1
    }

    /// Removes the attachments for sending; the shared window stays until the user removes it.
    func takeAttachments() -> [Attachment] {
        let taken = attachments
        attachments = []
        return taken
    }

    func remove(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func takePaths() -> [URL] {
        let taken = paths
        paths = []
        return taken
    }

    func remove(path: URL) {
        paths.removeAll { $0 == path }
    }

    /// Adds files. For running commands any file or folder goes in by its path; otherwise images,
    /// PDFs and text files are copied in and anything else is refused with a notice.
    func add(fileURLs: [URL], asPaths: Bool = false) {
        if asPaths {
            for url in fileURLs where !paths.contains(url) {
                paths.append(url.standardizedFileURL)
            }
            return
        }
        for url in fileURLs {
            let attachmentName = url.lastPathComponent
            guard Self.canSend(url) else {
                show(notice: String(localized: "\(attachmentName) can't be sent. Images, PDFs and text files work."))
                continue
            }
            do {
                attachments.append(try app.fileService.importFile(at: url))
            } catch {
                show(notice: String(localized: "\(attachmentName) couldn't be added."))
            }
        }
    }

    func add(imageData: Data, fileName: String) {
        do {
            attachments.append(try app.fileService.importData(imageData, fileName: fileName))
        } catch {
            show(notice: String(localized: "The image couldn't be added."))
        }
    }

    func show(notice: String) {
        self.notice = notice
        noticeTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.notice = nil }
        }
        noticeTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    private func saveAttachmentIDs() {
        defaults.set(attachments.map(\.id.uuidString), forKey: Self.attachmentsKey)
    }

    static func canSend(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if Attachment.imageExtensions.contains(ext) || ext == "pdf" { return true }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxTextFileSize,
              let data = try? Data(contentsOf: url)
        else { return false }
        return String(data: data, encoding: .utf8) != nil
    }
}

/// Heights of the input area, which grows a row for attachments and one for the sharing tag.
enum ComposerLayout {
    static let baseHeight: CGFloat = 54
    /// The input's corners are circular arcs of the same radius at every height, as in Gemini.
    static let shape = RoundedRectangle(cornerRadius: 24, style: .circular)
    static let attachmentsRowHeight: CGFloat = 64
    static let tagRowHeight: CGFloat = 26
    static let noticeRowHeight: CGFloat = 16
    static let rowSpacing: CGFloat = 6
    /// A strip at the top of the input, for the selection or a notice: one line, 36 tall.
    static let stripHeight: CGFloat = 36
    /// As in Gemini, text above the buttons has its first line's center 27 from the top and its last
    /// line's 41 above the buttons' center, and the buttons sit 26 from the bottom, a little lower than
    /// in a single row: one line makes the bar 94 tall and each further line adds 20.
    static let textTop: CGFloat = 5
    static let textGap: CGFloat = 8
    static let expandedRowDrop: CGFloat = 1

    /// What text above the buttons adds to the bar's height.
    static func expandedExtra(textHeight: CGFloat) -> CGFloat {
        textHeight > 0 ? textTop + textHeight + textGap - expandedRowDrop : 0
    }

    /// `textHeight` is the height of text that moved above the buttons, or 0.
    @MainActor
    static func height(for composer: ComposerModel, textHeight: CGFloat = 0) -> CGFloat {
        var height = baseHeight
        height += expandedExtra(textHeight: textHeight)
        if composer.asksForAccessibility { height += stripHeight + rowSpacing }
        if let selection = composer.selection {
            height += (composer.selectionOpen ? StripMetrics.openHeight(of: selection) : stripHeight) + rowSpacing
        }
        if !composer.attachments.isEmpty || !composer.paths.isEmpty { height += attachmentsRowHeight + rowSpacing }
        if composer.sharedWindow != nil { height += tagRowHeight + rowSpacing }
        if composer.notice != nil { height += noticeRowHeight + rowSpacing }
        return height
    }
}

/// The selection's strip opened: its text 13 points, lines 20 apart, up to five lines before it scrolls.
enum StripMetrics {
    static let font = NSFont.systemFont(ofSize: 13)
    static let lineHeight: CGFloat = 20
    static let maxLines: CGFloat = 5
    static let verticalPadding: CGFloat = 8
    /// The mini window's input is 400 wide; the strip is inset 8 from it, and its text leaves room for the
    /// mark before it and the close button after it.
    static let textWidth: CGFloat = 400 - 16 - 12 - 16 - 8 - 8 - 24 - 6

    static func quoted(_ text: String) -> String {
        "\u{201C}\(text)\u{201D}"
    }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    /// What SwiftUI adds between lines to put them 20 apart.
    @MainActor
    static var lineSpacing: CGFloat {
        max(0, lineHeight - NSLayoutManager().defaultLineHeight(for: font))
    }

    /// The text's own height, all of it.
    static func textHeight(of text: String, width: CGFloat = textWidth) -> CGFloat {
        let rect = (quoted(text) as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraphStyle]
        )
        return ceil(rect.height)
    }

    /// The strip's height opened: the text up to five lines, with padding above and below.
    static func openHeight(of text: String) -> CGFloat {
        min(textHeight(of: text), lineHeight * maxLines) + verticalPadding * 2
    }
}
