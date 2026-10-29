import AppKit
import SpotCore

/// The + menu's work for one window: uploads, sharing a window, the permission guide, and sending.
@MainActor
final class InputActions {
    let composer: ComposerModel
    let app: AppModel
    let share: WindowShareService
    let guide: PermissionGuideController

    init(composer: ComposerModel, app: AppModel, share: WindowShareService, guide: PermissionGuideController) {
        self.composer = composer
        self.app = app
        self.share = share
        self.guide = guide
    }

    /// `presenting` wraps work that shows another window; it calls the completion when that window is gone.
    func makeActions(
        submit: @escaping () -> Void,
        escape: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        presenting: @escaping ((@escaping () -> Void) -> Void) -> Void,
        menuWillOpen: @escaping () -> Void = {},
        menuDidClose: @escaping () -> Void = {}
    ) -> ComposerActions {
        ComposerActions(
            submit: submit,
            escape: escape,
            openSettings: openSettings,
            uploadImages: { [weak self] in self?.upload(imagesOnly: true, presenting: presenting) },
            uploadFiles: { [weak self] in self?.upload(imagesOnly: false, presenting: presenting) },
            shareWindow: { [weak self] window in
                self?.composer.sharedWindow = window
                self?.composer.requestFocus()
            },
            showPermissionGuide: { [weak self] in
                guard let self else { return }
                presenting { finished in
                    self.guide.show { _ in finished() }
                }
            },
            loadWindows: { [weak self] in
                guard let self, WindowShareService.hasScreenRecordingPermission else { return nil }
                return await self.share.windows()
            },
            menuWillOpen: menuWillOpen,
            menuDidClose: menuDidClose
        )
    }

    private func upload(imagesOnly: Bool, presenting: @escaping ((@escaping () -> Void) -> Void) -> Void) {
        presenting { [weak self] finished in
            AttachmentPicker.pick(imagesOnly: imagesOnly) { urls in
                self?.composer.add(fileURLs: urls)
                finished()
            }
        }
    }

    /// Sends the message with the attachments, capturing the shared window first.
    func send(text: String, to session: ChatSession, newTopicID: UUID) {
        let attachments = composer.takeAttachments()
        guard let shared = composer.sharedWindow else {
            session.send(text: text, attachments: attachments, newTopicID: newTopicID)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var all = attachments
            if let capture = await self.share.captureAttachment(shared, into: self.composer, files: self.app) {
                all.append(capture)
            }
            session.send(text: text, attachments: all, newTopicID: newTopicID)
        }
    }
}
