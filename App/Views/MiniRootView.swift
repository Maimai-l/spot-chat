import SwiftUI
import SpotCore

struct MiniRootView: View {
    @ObservedObject var controller: MiniWindowController

    var body: some View {
        Group {
            switch controller.mode {
            case .card:
                CardView(controller: controller)
            case .capsule, .hidden:
                CapsuleView(controller: controller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The collapsed mini window: + · input · model · expand.
struct CapsuleView: View {
    @ObservedObject var controller: MiniWindowController

    var body: some View {
        HStack(spacing: 6) {
            CircleIconButton(systemName: "plus", label: "添加附件或分享窗口") {}
                .disabled(true)
            ComposerField(
                text: $controller.draft,
                placeholder: "问问 Spot",
                focusRequest: controller.focusRequest,
                onSubmit: controller.submit,
                onEscape: { controller.handle(.escape) }
            )
            .frame(height: 28)
            ModelNameLabel(name: controller.modelName)
            CircleIconButton(systemName: "arrow.up.left.and.arrow.down.right", label: "展开为完整窗口") {}
                .disabled(true)
        }
        .padding(.horizontal, 10)
        .frame(height: MiniWindowController.capsuleHeight)
        .background(WindowDragArea(onDragEnd: controller.panelWasDragged))
        .background(VisualEffectBackground(material: .popover))
        .clipShape(Capsule(style: .continuous))
    }
}

/// The expanded mini window: header buttons, conversation, input pinned to the bottom.
struct CardView: View {
    @ObservedObject var controller: MiniWindowController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CircleIconButton(systemName: "xmark", label: "关闭", filled: true) {
                    controller.handle(.closeCard)
                }
                Spacer()
                CircleIconButton(systemName: "square.and.pencil", label: "新对话", filled: true) {
                    controller.handle(.newConversation)
                }
                CircleIconButton(systemName: "arrow.up.left.and.arrow.down.right", label: "展开为完整窗口", filled: true) {}
                    .disabled(true)
            }
            .padding(12)
            .background(WindowDragArea(onDragEnd: controller.panelWasDragged))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(controller.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                }
                .onChange(of: controller.scrollRequest) {
                    scrollToBottom(proxy)
                }
                .onChange(of: controller.messages) {
                    scrollToBottom(proxy)
                }
                .onAppear {
                    scrollToBottom(proxy)
                }
            }

            HStack(spacing: 6) {
                CircleIconButton(systemName: "plus", label: "添加附件或分享窗口") {}
                    .disabled(true)
                ComposerField(
                    text: $controller.draft,
                    placeholder: "问问 Spot",
                    focusRequest: controller.focusRequest,
                    onSubmit: controller.submit,
                    onEscape: { controller.handle(.escape) }
                )
                .frame(height: 28)
                ModelNameLabel(name: controller.modelName)
            }
            .padding(.horizontal, 10)
            .frame(height: MiniWindowController.capsuleHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 1)
            )
            .padding(10)
        }
        .background(WindowDragArea(onDragEnd: controller.panelWasDragged))
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = controller.messages.last?.id else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .accessibilityIdentifier("message.user")
            }
        case .assistant:
            Text(message.text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("message.assistant")
        }
    }
}

struct ModelNameLabel: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 8)
            .accessibilityIdentifier("modelName")
    }
}

struct CircleIconButton: View {
    let systemName: String
    let label: String
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .background {
                    if filled {
                        Circle()
                            .fill(Color(nsColor: .textBackgroundColor))
                            .shadow(color: .black.opacity(0.12), radius: 5, y: 1)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
