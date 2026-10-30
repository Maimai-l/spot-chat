import AppKit
import SwiftUI
import SpotAgent
import SpotCore

/// The commands of a reply, folded under "Ran 2 commands". Open while they run, so what is happening
/// is in view; each shows what it does, the command, and the end of its output.
struct CommandRunsView: View {
    let runs: [CommandRun]
    let isLive: Bool
    let stop: () -> Void
    @State private var isOpen: Bool
    @State private var hovering = false

    init(runs: [CommandRun], isLive: Bool, stop: @escaping () -> Void) {
        self.runs = runs
        self.isLive = isLive
        self.stop = stop
        _isOpen = State(initialValue: isLive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("Ran \(runs.count) commands")
                        .font(.system(size: 14))
                        .foregroundStyle(hovering ? .primary : .secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityIdentifier("commands")

            if isOpen {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(runs) { run in
                        CommandRunRow(run: run, stop: stop)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 2)
                }
                .transition(.opacity)
            }
        }
        .onChange(of: isLive) { _, live in
            if live { isOpen = true }
        }
    }
}

struct CommandRunRow: View {
    let run: CommandRun
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CommandStateIcon(state: run.state)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if run.state == .running {
                    Button("Stop", action: stop)
                        .controlSize(.small)
                        .accessibilityIdentifier("stopCommand")
                } else if let duration = run.duration, run.state != .denied {
                    Text(Self.format(duration))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            if !run.detail.isEmpty {
                Text(run.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .accessibilityIdentifier("commandText")
            }
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(run.outsideFolder ? Color.orange : .secondary)
                    .accessibilityIdentifier("commandNote")
            }
            if !run.output.isEmpty {
                Text(run.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("commandOutput")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command.\(run.state.rawValue)")
    }

    private var title: String {
        if !run.summary.isEmpty { return run.summary }
        switch run.tool {
        case .shell: return String(localized: "Run Command")
        case .webSearch: return String(localized: "Search the Web")
        case .webFetch: return String(localized: "Open Page")
        case .other: return String(localized: "Use a Tool")
        }
    }

    private var note: String? {
        switch run.state {
        case .blocked: return String(localized: "Stopped by the sandbox")
        case .denied: return String(localized: "Denied")
        case .stopped: return String(localized: "Stopped")
        case .waitingForApproval: return String(localized: "Waiting for your answer")
        case .running, .succeeded, .failed:
            if run.outsideFolder { return String(localized: "Ran outside the folder") }
            if run.state == .failed, let code = run.exitCode { return String(localized: "Exited with code \(code)") }
            return nil
        }
    }

    static func format(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(localized: "\(duration, format: .number.precision(.fractionLength(1))) s")
        }
        return Duration.seconds(duration.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }
}

struct CommandStateIcon: View {
    let state: CommandRun.State

    var body: some View {
        Group {
            switch state {
            case .running, .waitingForApproval:
                ProgressView().controlSize(.mini)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .blocked, .denied:
                Image(systemName: "hand.raised.circle.fill").foregroundStyle(.secondary)
            case .stopped:
                Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
        .frame(width: 16, height: 16)
    }
}

/// Asks before dsh runs a command outside the folder. That one runs without the sandbox.
struct CommandApprovalCard: View {
    let run: CommandRun
    let folderName: String
    let answer: (CommandApproval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run this command outside \(folderName)?")
                .font(.system(size: 15, weight: .semibold))
            if let justification = run.justification, !justification.isEmpty {
                Text(justification)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(run.detail)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            Label("This one runs without the sandbox", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.orange.opacity(0.12)))
            HStack(spacing: 8) {
                Spacer()
                Button {
                    answer(.deny)
                } label: {
                    HStack(spacing: 6) {
                        Text("Deny")
                        Text("esc").foregroundStyle(.secondary)
                    }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("denyCommand")
                Button {
                    answer(.allow)
                } label: {
                    HStack(spacing: 6) {
                        Text("Allow Once")
                        Text("⌘↩").opacity(0.7)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("allowCommand")
            }
            .controlSize(.large)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commandApproval")
    }
}

/// A file or folder a question points to by its path; its contents aren't sent.
struct PathTile: View {
    let url: URL
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.shortPath(of: url.deletingLastPathComponent()))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove"))
                .accessibilityIdentifier("removePath")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 10 : 4)
        .frame(height: 44)
        .frame(maxWidth: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12))
        )
        .help(url.path)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("path")
    }

    /// "~/Movies" rather than "/Users/name/Movies".
    static func shortPath(of url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// "Run Commands Movies" next to the +: where the conversation runs commands. Its menu changes the
/// folder or turns commands off.
struct CommandFolderChip: View {
    let folder: URL
    let chooseFolder: () -> Void
    let turnOff: () -> Void

    var body: some View {
        Menu {
            Button("Choose Another Folder…", action: chooseFolder)
            Button("Stop Running Commands", action: turnOff)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 12))
                Text("Run Commands \(folder.lastPathComponent)")
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(PathTile.shortPath(of: folder))
        .accessibilityIdentifier("commandFolder")
    }
}
