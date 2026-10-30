import AppKit
import SwiftUI
import SpotCore

/// The conversation, scrolled to the newest message.
struct MessageList: View {
    @ObservedObject var session: ChatSession
    var scrollRequest: Int
    var topInset: CGFloat
    var horizontalPadding: CGFloat
    var maxContentWidth: CGFloat = .infinity

    var body: some View {
        ScrollViewReader { proxy in
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
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .frame(maxWidth: maxContentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, topInset)
                .padding(.bottom, 8)
                .background(OverlayScrollers())
            }
            .onChange(of: scrollRequest) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            // A reply's height is known only once its page has rendered, after the message changed.
            .environment(\.replyDidResize) { id in
                if id == session.messages.last?.id {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private static let bottomID = "bottom"
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
        .opacity(showsActions ? 1 : 0)
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
