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
                    Text("Ran \(shown.count) commands")
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
                    ForEach(shown) { run in
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

    /// The commands without a try the sandbox stopped when dsh then asked to run the same command
    /// outside it: the question says all that try did.
    private var shown: [CommandRun] {
        runs.enumerated().compactMap { index, run in
            let retried = run.state == .blocked && runs[(index + 1)...].contains { $0.detail == run.detail }
            return retried ? nil : run
        }
    }
}

struct CommandRunRow: View {
    let run: CommandRun
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CommandStateIcon(run: run)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
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
            if run.state == .waitingForApproval {
                NeedsInputPill()
            }
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
        case .waitingForApproval: return nil
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

/// What the command is, in gray as the rest of the conversation: a spinner while it runs, otherwise
/// the tool's icon. How it ended is said in words below, not in colors.
struct CommandStateIcon: View {
    let run: CommandRun

    var body: some View {
        Group {
            if !run.isFinished {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: symbol)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
    }

    private var symbol: String {
        switch run.tool {
        case .shell: return "apple.terminal"
        case .webSearch: return "magnifyingglass"
        case .webFetch: return "globe"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// Asks before dsh runs a command outside the folder, docked above the input as Claude does: what it
/// wants in one line, the details in a gray block, then Decline and Allow Once.
struct CommandApprovalCard: View {
    let run: CommandRun
    let folderName: String
    let answer: (CommandApproval) -> Void
    @State private var showsWholeCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showsWholeCommand.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Spot wants to run a command outside \(folderName)")
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsWholeCommand ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    detailLabel("Command")
                    Text(run.detail)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(showsWholeCommand ? nil : 3)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("approvalCommand")
                }
                if let justification = run.justification, !justification.isEmpty {
                    GridRow {
                        detailLabel("Reason")
                        Text(justification)
                    }
                }
                GridRow {
                    detailLabel("Sandbox")
                    Text("Off for this command")
                }
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))

            HStack {
                Button { answer(.deny) } label: {
                    HStack(spacing: 6) {
                        Text("Decline")
                        KeyCaps(keys: ["Esc"])
                    }
                }
                .buttonStyle(ApprovalButtonStyle(prominent: false))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("denyCommand")
                Spacer()
                Button { answer(.allow) } label: {
                    HStack(spacing: 6) {
                        Text("Allow Once")
                        KeyCaps(keys: ["⌘", "↩"])
                    }
                }
                .buttonStyle(ApprovalButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("allowCommand")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.1))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commandApproval")
    }

    private func detailLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }
}

/// The two buttons of the approval card: gray, or black (white in dark mode) for the one that goes ahead.
struct ApprovalButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color(nsColor: .textBackgroundColor) : Color.primary)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Color.primary : Color.primary.opacity(0.06))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .environment(\.keyCapsOnDark, prominent)
    }
}

/// Keys shown in small boxes after a button's name, such as Esc or ⌘ ↩.
struct KeyCaps: View {
    let keys: [String]
    @Environment(\.keyCapsOnDark) private var onDark

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(verbatim: key)
                    .font(.system(size: 11))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 18, minHeight: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(onDark ? Color(nsColor: .textBackgroundColor).opacity(0.35) : Color.primary.opacity(0.15))
                    )
                    .opacity(0.8)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct KeyCapsOnDarkKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var keyCapsOnDark: Bool {
        get { self[KeyCapsOnDarkKey.self] }
        set { self[KeyCapsOnDarkKey.self] = newValue }
    }
}

/// Marks the step that waits for the user, the one color in a conversation of commands.
struct NeedsInputPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.needsInput)
                .frame(width: 8, height: 8)
                .padding(3)
                .overlay(Circle().stroke(Color.needsInput.opacity(0.4), lineWidth: 1.5))
            Text("Needs your input")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.55, green: 0.36, blue: 0.05))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .overlay(Capsule().stroke(Color.needsInput.opacity(0.4)))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("needsInput")
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
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
            Divider()
            Button("Stop Running Commands", action: turnOff)
        } label: {
            // Where there is no room for the whole label, the icon stands for "Run Commands".
            ViewThatFits(in: .horizontal) {
                label(Text("Run Commands \(folder.lastPathComponent)"))
                label(Text(folder.lastPathComponent))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(PathTile.shortPath(of: folder))
        .accessibilityIdentifier("commandFolder")
    }

    private func label(_ text: Text) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 12))
            text
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
