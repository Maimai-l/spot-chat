import AppKit
import SwiftUI
import SpotCore

/// The conversation, scrolled to the newest message. The system scroll bar is replaced by a thin one
/// that shows only while the reader scrolls, so no scroll bar track ever borders the conversation.
struct MessageList: View {
    @ObservedObject var session: ChatSession
    var scrollRequest: Int
    var topInset: CGFloat
    var horizontalPadding: CGFloat
    var maxContentWidth: CGFloat = .infinity

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var metrics = ScrollMetrics()
    @State private var scrolling = false
    /// Bumped when the reader moves the conversation, including with a mouse wheel.
    @State private var readerScrolls = 0
    /// Scrolling until this moment follows a reply and doesn't show the scroll bar.
    @State private var followingUntil = Date.distantPast

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(session.messages) { message in
                    MessageRow(
                        message: message,
                        isLast: message.id == session.messages.last?.id,
                        isGenerating: session.isGenerating,
                        retry: { session.retry(message.id) },
                        regenerate: { session.regenerateLastReply() },
                        edit: { session.edit(message.id, text: $0) }
                    )
                    .id(message.id)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.messages.count)
            .frame(maxWidth: maxContentWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topInset)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offset: geometry.contentOffset.y,
                content: geometry.contentSize.height,
                visible: geometry.containerSize.height
            )
        } action: { old, new in
            metrics = new
            if abs(new.offset - old.offset) > 0.5, Date() > followingUntil {
                readerScrolls += 1
            }
        }
        // Only the reader's own scrolling shows the bar, not the conversation following a reply.
        .onScrollPhaseChange { _, phase in
            scrolling = phase == .interacting || phase == .tracking || phase == .decelerating
        }
        .overlay(alignment: .topTrailing) {
            ScrollIndicator(
                metrics: metrics,
                isScrolling: scrolling,
                readerScrolls: readerScrolls,
                topInset: max(topInset - 16, 8),
                scrollTo: { position.scrollTo(y: $0) }
            )
        }
        .onChange(of: scrollRequest) {
            followBottom(animated: true)
        }
        // A reply's height is known only once its page has rendered, after the message changed.
        .environment(\.replyDidResize) { id in
            if id == session.messages.last?.id {
                followBottom(animated: true)
            }
        }
        .onAppear {
            followBottom(animated: false)
        }
    }

    /// Keeps the newest message in view; animated, it glides rather than jumps.
    private func followBottom(animated: Bool) {
        followingUntil = Date().addingTimeInterval(0.5)
        if animated {
            withAnimation(.easeOut(duration: 0.22)) { position.scrollTo(edge: .bottom) }
        } else {
            position.scrollTo(edge: .bottom)
        }
    }
}

struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var visible: CGFloat = 0

    var maxOffset: CGFloat { max(content - visible, 0) }
}

/// A thin scroll bar drawn over the conversation's trailing edge. It appears while the reader scrolls
/// or points at it, fades out a moment after, and can be dragged.
struct ScrollIndicator: View {
    let metrics: ScrollMetrics
    let isScrolling: Bool
    /// Changes each time the reader moves the conversation; shows the bar for a moment.
    var readerScrolls = 0
    var topInset: CGFloat = 8
    var bottomInset: CGFloat = 8
    let scrollTo: (CGFloat) -> Void

    @State private var shown = false
    @State private var hovering = false
    @State private var dragStartOffset: CGFloat?
    @State private var hideTask: Task<Void, Never>?

    private var active: Bool { hovering || dragStartOffset != nil }

    var body: some View {
        GeometryReader { geometry in
            let track = max(geometry.size.height - topInset - bottomInset, 1)
            let thumb = min(max(track * metrics.visible / max(metrics.content, 1), 32), track)
            let travel = max(track - thumb, 1)
            let progress = metrics.maxOffset > 0 ? min(max(metrics.offset / metrics.maxOffset, 0), 1) : 0
            Capsule()
                .fill(Color.primary.opacity(active ? 0.45 : 0.3))
                .frame(width: active ? 8 : 6, height: thumb)
                .frame(width: 14, height: thumb)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = dragStartOffset ?? metrics.offset
                            dragStartOffset = start
                            let offset = start + value.translation.height * metrics.maxOffset / travel
                            scrollTo(min(max(offset, 0), metrics.maxOffset))
                        }
                        .onEnded { _ in
                            dragStartOffset = nil
                            scheduleHide()
                        }
                )
                .offset(x: geometry.size.width - 14 - 2, y: topInset + travel * progress)
                .opacity(shown || active ? 1 : 0)
                .allowsHitTesting(shown || active)
                .animation(.easeOut(duration: 0.12), value: active)
        }
        .opacity(metrics.maxOffset > 1 ? 1 : 0)
        .onChange(of: isScrolling) {
            if isScrolling {
                hideTask?.cancel()
                withAnimation(.easeOut(duration: 0.12)) { shown = true }
            } else {
                scheduleHide()
            }
        }
        .onChange(of: readerScrolls) {
            withAnimation(.easeOut(duration: 0.12)) { shown = true }
            scheduleHide()
        }
        .onChange(of: hovering) {
            if !hovering { scheduleHide() }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !isScrolling, !active else { return }
            withAnimation(.easeOut(duration: 0.3)) { shown = false }
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let isLast: Bool
    let isGenerating: Bool
    let retry: () -> Void
    let regenerate: () -> Void
    let edit: (String) -> Void

    var body: some View {
        switch message.role {
        case .user:
            UserMessageView(message: message, canEdit: !isGenerating, onEdit: edit)
        case .assistant:
            AssistantMessageView(
                message: message,
                canRegenerate: isLast && !isGenerating,
                retry: retry,
                regenerate: regenerate
            )
        }
    }
}

/// The question, with Edit and Copy below it under the pointer, as in Claude. Editing turns it into a
/// field; Save replaces the question and the replies after it.
struct UserMessageView: View {
    let message: ChatMessage
    let canEdit: Bool
    let onEdit: (String) -> Void

    @State private var hovering = false
    @State private var editing = false
    @State private var editText = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !message.attachments.isEmpty {
                AttachmentStrip(attachments: message.attachments)
            }
            if editing {
                editor
            } else if !message.text.isEmpty {
                bubble
                    .padding(.leading, 60)
                HStack(spacing: 2) {
                    if canEdit {
                        SmallIconButton(systemName: "pencil", label: "Edit", identifier: "editMessage") {
                            editText = message.text
                            editing = true
                        }
                    }
                    SmallIconButton(systemName: "doc.on.doc", label: "Copy", identifier: "copyMessage") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                }
                // The buttons stay clickable while hidden, so keyboard and test clicks reach them too.
                .environment(\.showsMessageActions, hovering)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var bubble: some View {
        Text(message.text)
            .font(.system(size: 16))
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 6,
                    style: .continuous
                )
                .fill(Color.primary.opacity(0.07))
            )
            .accessibilityIdentifier("message.user")
    }

    private var isChanged: Bool {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("", text: $editText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineLimit(1...10)
                .focused($editFocused)
                .onAppear { editFocused = true }
                .onSubmit(save)
                .onExitCommand(perform: cancel)
                .accessibilityIdentifier("editField")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                )
            HStack(spacing: 6) {
                Button(action: cancel) {
                    Text("Cancel")
                        .font(.system(size: 14))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cancelEdit")
                Button(action: save) {
                    Text("Save")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isChanged ? Color(nsColor: .textBackgroundColor) : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isChanged ? Color.primary : Color.primary.opacity(0.06))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isChanged)
                .accessibilityIdentifier("saveEdit")
            }
        }
    }

    private func cancel() {
        editing = false
    }

    private func save() {
        guard isChanged else { return }
        editing = false
        onEdit(editText)
    }
}

extension EnvironmentValues {
    /// Whether the pointer is over the message, which shows its Copy and Edit buttons.
    @Entry var showsMessageActions = true
}

struct AssistantMessageView: View {
    let message: ChatMessage
    let canRegenerate: Bool
    let retry: () -> Void
    let regenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SpotMark(size: 22)
            if !message.text.isEmpty {
                ReplyView(id: message.id, markdown: message.text, isStreaming: message.status == .pending)
            } else if message.status == .pending {
                ProgressView()
                    .controlSize(.small)
            }
            if message.status == .error {
                ErrorBox(message: message.errorMessage ?? "", retry: retry)
            } else if message.status != .pending {
                actions
            }
        }
        .overlay(alignment: .topLeading) {
            // The reply's full text as one element, so tests and assistive apps can read it at once.
            Text(message.text)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityIdentifier("message.assistant")
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            SmallIconButton(systemName: "doc.on.doc", label: "Copy", identifier: "copyReply") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
            if canRegenerate {
                SmallIconButton(systemName: "arrow.clockwise", label: "Regenerate", identifier: "regenerate", action: regenerate)
            }
        }
        .padding(.leading, -6)
    }
}

struct ErrorBox: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 16))
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 13))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("message.error")
            Button(action: retry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("retry")
        }
        .foregroundStyle(Color(red: 0.55, green: 0.11, blue: 0.09))
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.99, green: 0.93, blue: 0.93))
        )
        .environment(\.colorScheme, .light)
    }
}

struct SmallIconButton: View {
    @Environment(\.showsMessageActions) private var showsActions
    let systemName: String
    let label: LocalizedStringKey
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Nearly, not fully, transparent: SwiftUI drops fully transparent views from accessibility.
        .opacity(showsActions ? 1 : 0.001)
        .animation(.easeOut(duration: 0.12), value: showsActions)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }
}

/// The app's mark shown above each reply: a blue dot with a highlight.
struct SpotMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.18, green: 0.44, blue: 0.92))
            Circle()
                .fill(.white)
                .frame(width: size * 0.22, height: size * 0.22)
                .offset(x: size * 0.15, y: -size * 0.15)
        }
        .frame(width: size * 0.75, height: size * 0.75)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Attachments shown above a sent message.
struct AttachmentStrip: View {
    let attachments: [SpotCore.Attachment]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { attachment in
                AttachmentTile(attachment: attachment, onRemove: nil)
            }
        }
    }
}

struct AttachmentTile: View {
    let attachment: SpotCore.Attachment
    let onRemove: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.kind == .image, let image = NSImage(contentsOf: attachment.fileURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32, height: 36)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(attachment.ext?.uppercased() ?? "")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 180, height: 56, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.12))
                    )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(attachment.displayName))
            .accessibilityIdentifier("attachment")

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary))
                        .overlay(Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel(Text("Remove"))
                .accessibilityIdentifier("removeAttachment")
            }
        }
    }
}
