import AppKit
import SwiftUI
import Textual
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
                            regenerate: { session.regenerateLastReply() }
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
            }
            .onChange(of: scrollRequest) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
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

    var body: some View {
        switch message.role {
        case .user:
            UserMessageView(message: message)
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

struct UserMessageView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                AttachmentStrip(attachments: message.attachments)
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .accessibilityIdentifier("message.user")
            }
        }
        .padding(.leading, 60)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
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
                StructuredText(markdown: message.text)
                    .font(.system(size: 15))
                    .textual.textSelection(.enabled)
                    .textual.codeBlockStyle(SpotCodeBlockStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.assistant")
        .accessibilityValue(Text(message.text))
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

/// Code blocks with the language on the left and a copy button on the right.
struct SpotCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.languageHint ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    configuration.codeBlock.copyToPasteboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("copyCode")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            Overflow {
                configuration.label
                    .monospaced()
                    .textual.fontScale(0.88)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
        }
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        )
        .textual.blockSpacing(.init(top: 4, bottom: 12))
    }
}

/// Attachments shown above a sent message.
struct AttachmentStrip: View {
    let attachments: [Attachment]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { attachment in
                AttachmentTile(attachment: attachment, onRemove: nil)
            }
        }
    }
}

struct AttachmentTile: View {
    let attachment: Attachment
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
                .offset(x: 6, y: -6)
                .accessibilityLabel(Text("Remove"))
                .accessibilityIdentifier("removeAttachment")
            }
        }
    }
}
