import AppKit
import SwiftUI
import SpotAgent
import SpotCore

/// What a reply did, folded under one line as in Claude: "Ran 2 commands, searched the web, read 2 pages".
/// Open while the reply is being made. Open, the steps are lines joined by a thin thread through their icons,
/// and each opens in place to its details (docs/design/steps.html). Opening or closing keeps the line clicked
/// where it is: what opens grows below it.
struct CommandRunsView: View {
    let runs: [CommandRun]
    let isLive: Bool
    let stop: () -> Void
    @State private var isOpen: Bool
    @Environment(\.holdReaderPlace) private var holdReaderPlace

    init(runs: [CommandRun], isLive: Bool, stop: @escaping () -> Void) {
        self.runs = runs
        self.isLive = isLive
        self.stop = stop
        _isOpen = State(initialValue: isLive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                holdReaderPlace()
                withAnimation(StepMotion.open) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(Self.summary(of: shown))
                        .font(.system(size: 14))
                    StepChevron(isOpen: isOpen)
                }
            }
            .buttonStyle(StepLineStyle(height: 28))
            .accessibilityIdentifier("commands")

            if isOpen {
                let steps = shown
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(steps) { run in
                        CommandRunRow(run: run, stop: stop, isFirst: run.id == steps.first?.id, isLast: run.id == steps.last?.id)
                    }
                }
                .transition(.opacity)
            }
        }
        .onChange(of: isLive) { _, live in
            if live { isOpen = true }
        }
    }

    /// The steps without a try the sandbox stopped when dsh then asked to run the same command
    /// outside it: the question says all that try did.
    private var shown: [CommandRun] {
        runs.enumerated().compactMap { index, run in
            let retried = run.state == .blocked && runs[(index + 1)...].contains { $0.detail == run.detail }
            return retried ? nil : run
        }
    }

    static func summary(of runs: [CommandRun]) -> String {
        let commands = runs.filter { $0.tool == .shell }.count
        let searches = runs.filter { $0.tool == .webSearch }.count
        let pages = runs.filter { $0.tool == .webFetch }.count
        let others = runs.filter { $0.tool == .other }.count
        var parts: [String] = []
        if commands > 0 { parts.append(String(localized: "Ran \(commands) commands")) }
        if searches > 0 { parts.append(String(localized: "Searched the web")) }
        if pages > 0 { parts.append(String(localized: "Read \(pages) pages")) }
        if others > 0 { parts.append(String(localized: "Used \(others) tools")) }
        // Sentence case: "Searched the web, read 2 pages".
        let joined = parts.enumerated().map { index, part in
            index == 0 ? part : part.prefix(1).lowercased() + part.dropFirst()
        }
        return joined.joined(separator: String(localized: ", "))
    }
}

/// How the steps open and close: the height in 0.2 seconds, the line clicked staying put.
enum StepMotion {
    static let open = Animation.easeOut(duration: 0.2)
}

/// A line that opens something: all of it clickable, with a light gray behind it under the pointer, so it
/// shows at once that it can be clicked. Gray words turn black under the pointer.
struct StepLineStyle: ButtonStyle {
    static let rowHeight: CGFloat = 32
    var height: CGFloat = StepLineStyle.rowHeight
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        StepLine(configuration: configuration, height: height, enabled: enabled)
    }

    private struct StepLine: View {
        let configuration: Configuration
        let height: CGFloat
        let enabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering && enabled ? .primary : .secondary)
                .frame(height: height)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.09 : hovering ? 0.06 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, -8)
                .onHover { hovering = $0 }
        }
    }
}

/// One step as a line: its tool's icon on the thread, what it did in gray and what it did it to in black,
/// then the results it found or how long it took. Opening it shows a search's results, or the command and
/// what it printed in one gray block.
struct CommandRunRow: View {
    let run: CommandRun
    let stop: () -> Void
    var isFirst = true
    var isLast = true
    @State private var isOpen = false
    @Environment(\.holdReaderPlace) private var holdReaderPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasDetails else { return }
                holdReaderPlace()
                withAnimation(StepMotion.open) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    CommandStateIcon(run: run)
                    title
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    trailing
                    if hasDetails {
                        StepChevron(isOpen: isOpen)
                    }
                }
            }
            .buttonStyle(StepLineStyle(enabled: hasDetails))
            .accessibilityIdentifier("toolRow")

            VStack(alignment: .leading, spacing: 6) {
                if run.state == .waitingForApproval {
                    NeedsInputPill()
                }
                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("commandNote")
                }
                if isOpen {
                    details
                        .padding(.top, 2)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 24)
            .padding(.bottom, isOpen || note != nil || run.state == .waitingForApproval ? 8 : 0)
        }
        .background(alignment: .topLeading) { thread }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command.\(run.state.rawValue)")
    }

    /// The thread joining this step's icon to the ones above and below it, with a gap around the icon.
    private var thread: some View {
        let middle = StepLineStyle.rowHeight / 2
        let gap: CGFloat = 11
        return VStack(spacing: 0) {
            Rectangle().fill(isFirst ? Color.clear : Color.primary.opacity(0.1)).frame(width: 1, height: middle - gap)
            Spacer().frame(height: gap * 2)
            Rectangle().fill(isLast ? Color.clear : Color.primary.opacity(0.1)).frame(width: 1)
        }
        .padding(.leading, 7.5)
        .accessibilityHidden(true)
    }

    private var title: Text {
        let verb = Text(verbText)
        guard let object = objectText else { return verb }
        return verb + Text(verbatim: " ") + Text(verbatim: object).foregroundStyle(.primary)
    }

    /// While a command runs, how long it has, so a long one doesn't look stuck, and Stop; once it ends, how
    /// long it took. A search shows how many results it found.
    @ViewBuilder
    private var trailing: some View {
        if run.state == .running {
            if run.tool == .shell {
                TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
                    Text(Self.format(elapsed: context.date.timeIntervalSince(run.startedAt)))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            Button("Stop", action: stop)
                .controlSize(.small)
                .accessibilityIdentifier("stopCommand")
        } else if run.tool == .webSearch, let count = run.sources?.count, count > 0 {
            Text("\(count) results")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        } else if let duration = run.duration, run.state != .denied, run.tool == .shell {
            Text(Self.format(duration))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private var verbText: String {
        switch run.tool {
        case .shell: return run.summary.isEmpty ? String(localized: "Run Command") : run.summary
        case .webSearch: return String(localized: "Searched the web")
        case .webFetch: return String(localized: "Read")
        case .other: return run.summary.isEmpty ? String(localized: "Use a Tool") : run.summary
        }
    }

    /// The query or the page, after the verb.
    private var objectText: String? {
        switch run.tool {
        case .webSearch: return run.detail.isEmpty ? nil : run.detail
        case .webFetch: return run.pageTitle ?? WebSource(title: "", url: run.detail).host
        case .shell, .other: return nil
        }
    }

    private var hasDetails: Bool {
        switch run.tool {
        case .shell, .other: return !run.detail.isEmpty || !run.output.isEmpty
        case .webSearch: return !(run.sources ?? []).isEmpty
        case .webFetch: return !run.detail.isEmpty
        }
    }

    @ViewBuilder
    private var details: some View {
        switch run.tool {
        case .shell, .other:
            // The command and what it printed in one block, as a terminal shows them.
            VStack(alignment: .leading, spacing: 0) {
                if !run.detail.isEmpty {
                    (Text(verbatim: "$ ").foregroundStyle(.tertiary) + Text(verbatim: run.detail))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("commandText")
                }
                if !run.detail.isEmpty, !run.output.isEmpty {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
                }
                if !run.output.isEmpty {
                    // The end of what it printed, cut here rather than by the text view: a text view told
                    // to drop lines from the start reserved room for some and drew them all, over the steps below.
                    // One row per line, as a terminal shows it, so a long line doesn't wrap into many.
                    let lines = CommandOutput.tail(run.output, lines: Self.outputLines, lineLength: Self.outputLineLength)
                        .split(separator: "\n", omittingEmptySubsequences: false)
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line.isEmpty ? " " : String(line))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("commandOutput")
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        case .webSearch:
            WebResultsList(sources: run.sources ?? [])
        case .webFetch:
            if let url = URL(string: run.detail) {
                Link(run.detail, destination: url)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
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
            if run.state == .failed {
                if let code = run.exitCode { return String(localized: "Exited with code \(code)") }
                if run.tool != .shell { return String(localized: "Failed") }
            }
            return nil
        }
    }

    /// Lines of output shown, from the end, and the characters kept of each.
    static let outputLines = 12
    static let outputLineLength = 240

    /// Whole seconds while a command runs, as "12 s" or "2m 31s".
    static func format(elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        if seconds < 60 {
            return String(localized: "\(seconds, format: .number) s")
        }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }

    static func format(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(localized: "\(duration, format: .number.precision(.fractionLength(1))) s")
        }
        return Duration.seconds(duration.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }
}

/// A search's results in a gray block: the page's title, and its site at the end, each a line that opens in
/// the browser. Sites are marked with a globe rather than their icons, which would mean a request to every site.
struct WebResultsList: View {
    let sources: [WebSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sources, id: \.self) { source in
                Button {
                    if let url = URL(string: source.url) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(verbatim: source.title)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 12)
                        Text(verbatim: source.host)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(StepLineStyle(height: 30))
                .padding(.horizontal, 8)
                .help(source.url)
                .accessibilityIdentifier("searchResult")
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// A chevron after what folds, pointing down when open.
struct StepChevron: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
    }
}

/// The step's tool on the thread: a spinner while it runs, otherwise the tool's icon. How it ended is said
/// in words below, not in colors.
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

/// Marks the step that waits for the user: a dot in the accent color, as Mail marks unread mail.
/// The card above the input does the asking.
struct NeedsInputPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.needsInput)
                .frame(width: 7, height: 7)
            Text("Needs your input")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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
