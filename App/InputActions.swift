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
        session: ChatSession,
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
            menuDidClose: menuDidClose,
            toggleCommands: { [weak self, weak session] in
                guard let self, let session else { return }
                self.toggleCommands(in: session, presenting: presenting)
            },
            chooseCommandFolder: { [weak self, weak session] in
                guard let session else { return }
                self?.chooseFolder(for: session, presenting: presenting)
            },
            addPaths: { [weak self] in
                presenting { finished in
                    FolderPicker.pick(files: true) { urls in
                        self?.composer.add(fileURLs: urls, asPaths: true)
                        finished()
                    }
                }
            }
        )
    }

    /// Turns commands off, or on in a folder: the folder of the first file the input points to,
    /// otherwise one the user picks.
    private func toggleCommands(in session: ChatSession, presenting: @escaping ((@escaping () -> Void) -> Void) -> Void) {
        if session.commandFolder != nil {
            session.setCommandFolder(nil)
            return
        }
        if let first = composer.paths.first {
            let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            session.setCommandFolder(isFolder ? first : first.deletingLastPathComponent())
            return
        }
        chooseFolder(for: session, presenting: presenting)
    }

    private func chooseFolder(for session: ChatSession, presenting: @escaping ((@escaping () -> Void) -> Void) -> Void) {
        presenting { finished in
            FolderPicker.pick(files: false) { urls in
                if let folder = urls.first { session.setCommandFolder(folder) }
                finished()
            }
        }
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
        let paths = composer.takePaths()
        if session.commandFolder != nil {
            // dsh reads files where they are: copies made before commands were on go in by their path.
            session.send(text: text, attachments: [], paths: paths + attachments.map(\.fileURL), newTopicID: newTopicID)
            return
        }
        guard let shared = composer.sharedWindow else {
            session.send(text: text, attachments: attachments, paths: paths, newTopicID: newTopicID)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var all = attachments
            if let capture = await self.share.captureAttachment(shared, into: self.composer, files: self.app) {
                all.append(capture)
            }
            session.send(text: text, attachments: all, paths: paths, newTopicID: newTopicID)
        }
    }
}
