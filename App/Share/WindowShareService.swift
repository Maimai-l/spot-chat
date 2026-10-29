import AppKit
import ApplicationServices
import ScreenCaptureKit
import SpotCore

/// Lists open windows and captures one as an image, using ScreenCaptureKit.
@MainActor
final class WindowShareService {
    enum ShareError: LocalizedError {
        case windowClosed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .windowClosed:
                return String(localized: "The shared window was closed.")
            case .encodingFailed:
                return String(localized: "The shared window couldn't be captured.")
            }
        }
    }

    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Windows that can be shared, front to back. Empty without screen recording permission.
    func windows() async -> [SharableWindow] {
        guard Self.hasScreenRecordingPermission else { return [] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.map { window -> SharableWindow in
                let app = window.owningApplication
                var title = window.title ?? ""
                if title.isEmpty, let pid = app?.processID {
                    title = Self.accessibilityTitle(processID: pid, frame: window.frame) ?? ""
                }
                return SharableWindow(
                    id: window.windowID,
                    appName: app?.applicationName ?? "",
                    bundleID: app?.bundleIdentifier,
                    processID: app?.processID ?? 0,
                    title: title,
                    frame: window.frame,
                    layer: window.windowLayer,
                    isOnScreen: window.isOnScreen
                )
            }
            return SharableWindowFilter.filter(windows, excludingBundleID: Bundle.main.bundleIdentifier)
        } catch {
            return []
        }
    }

    /// The window's current contents as PNG data.
    func capture(_ window: SharableWindow) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == window.id }) else { throw ShareError.windowClosed }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ShareError.encodingFailed
        }
        return data
    }

    /// Captures the window and stores it as an attachment named after it.
    func captureAttachment(_ window: SharableWindow, into composer: ComposerModel, files: AppModel) async -> Attachment? {
        do {
            let data = try await capture(window)
            let name = window.label.replacingOccurrences(of: "/", with: "-")
            return try files.fileService.importData(data, fileName: "\(name).png")
        } catch {
            composer.show(notice: ErrorText.describe(error))
            return nil
        }
    }

    /// The title of the app's window at this frame, read through Accessibility when ScreenCaptureKit has none.
    private static func accessibilityTitle(processID: pid_t, frame: CGRect) -> String? {
        guard hasAccessibilityPermission else { return nil }
        let app = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        for window in windows {
            guard let windowFrame = frameOf(window), abs(windowFrame.minX - frame.minX) < 2, abs(windowFrame.minY - frame.minY) < 2,
                  abs(windowFrame.width - frame.width) < 2
            else { continue }
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
               let title = title as? String, !title.isEmpty {
                return title
            }
        }
        return nil
    }

    private static func frameOf(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        // swiftlint:disable:next force_cast
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}
