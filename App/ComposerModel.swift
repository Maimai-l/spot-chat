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
    /// Captured again each time a message is sent, so follow-up questions see the window as it is.
    @Published var sharedWindow: SharableWindow?
    @Published private(set) var focusRequest = 0
    /// A short message about something that could not be attached.
    @Published private(set) var notice: String?

    private let app: AppModel
    private let draftStorage: DraftStorage
    private let defaults: UserDefaults
    private var noticeTimer: DispatchWorkItem?
    private static let attachmentsKey = "SpotChat.pendingAttachments"

    init(app: AppModel, draftStorage: DraftStorage, defaults: UserDefaults = .standard) {
        self.app = app
        self.draftStorage = draftStorage
        self.defaults = defaults
        self.draft = draftStorage.loadDraft()
        let ids = (defaults.stringArray(forKey: Self.attachmentsKey) ?? []).compactMap(UUID.init(uuidString:))
        self.attachments = (try? app.fileService.attachments(withIDs: ids)) ?? []
    }

    var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || sharedWindow != nil
    }

    var hasExtras: Bool {
        !attachments.isEmpty || sharedWindow != nil
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

    /// Adds images, PDFs and text files. Anything else is refused with a notice.
    func add(fileURLs: [URL]) {
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
    static let baseHeight: CGFloat = 56
    static let attachmentsRowHeight: CGFloat = 64
    static let tagRowHeight: CGFloat = 26
    static let noticeRowHeight: CGFloat = 16
    static let rowSpacing: CGFloat = 6

    static func height(for composer: ComposerModel) -> CGFloat {
        var height = baseHeight
        if !composer.attachments.isEmpty { height += attachmentsRowHeight + rowSpacing }
        if composer.sharedWindow != nil { height += tagRowHeight + rowSpacing }
        if composer.notice != nil { height += noticeRowHeight + rowSpacing }
        return height
    }
}
