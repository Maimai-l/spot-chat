import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

/// Shown the first time the user shares a window without screen recording permission.
@MainActor
final class PermissionGuideController {
    private var window: NSWindow?

    /// Calls `finish` with true when the user is done and permission is granted.
    func show(finish: @escaping (Bool) -> Void) {
        window?.close()
        let view = PermissionGuideView(
            done: { [weak self] in
                self?.close()
                finish(WindowShareService.hasScreenRecordingPermission)
            },
            cancel: { [weak self] in
                self?.close()
                finish(false)
            }
        )
        let controller = NSHostingController(rootView: view)
        let window = EditingWindow(contentViewController: controller)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("permissionGuide")
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
    }
}

struct PermissionGuideView: View {
    let done: () -> Void
    let cancel: () -> Void

    @State private var screenGranted = WindowShareService.hasScreenRecordingPermission
    @State private var accessibilityGranted = WindowShareService.hasAccessibilityPermission
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            Text("Share Window Needs These Permissions")
                .font(.system(size: 20, weight: .semibold))
            VStack(spacing: 0) {
                PermissionRow(
                    title: "Screen & System Audio Recording",
                    detail: "Used to capture the window you choose",
                    granted: screenGranted,
                    open: openScreenRecordingSettings
                )
                Divider()
                PermissionRow(
                    title: "Accessibility",
                    detail: "Used to read window titles",
                    granted: accessibilityGranted,
                    open: openAccessibilitySettings
                )
            }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!screenGranted)
            }
        }
        .padding(28)
        .frame(width: 560)
        .onReceive(refresh) { _ in
            screenGranted = WindowShareService.hasScreenRecordingPermission
            accessibilityGranted = WindowShareService.hasAccessibilityPermission
        }
    }

    private func openScreenRecordingSettings() {
        // Asking once adds Spot Chat to the list in System Settings.
        _ = CGRequestScreenCaptureAccess()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ address: String) {
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Open System Settings", action: open)
            }
        }
        .padding(.vertical, 14)
    }
}

/// The system file picker, for images or any file.
enum AttachmentPicker {
    @MainActor
    static func pick(imagesOnly: Bool, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if imagesOnly {
            panel.allowedContentTypes = [.image]
        }
        NSApp.activate()
        panel.begin { response in
            completion(response == .OK ? panel.urls : [])
        }
    }
}

/// Picks files and folders that commands work on, or the folder they run in.
enum FolderPicker {
    @MainActor
    static func pick(files: Bool, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = files
        panel.prompt = files ? String(localized: "Add") : String(localized: "Choose")
        NSApp.activate()
        panel.begin { response in
            completion(response == .OK ? panel.urls : [])
        }
    }
}
