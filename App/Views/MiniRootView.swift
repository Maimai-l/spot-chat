import SwiftUI
import UniformTypeIdentifiers
import SpotCore

struct MiniRootView: View {
    @ObservedObject var controller: MiniWindowController
    @ObservedObject var session: ChatSession
    @ObservedObject var app: AppModel
    @ObservedObject var composer: ComposerModel

    var body: some View {
        Group {
            switch controller.mode {
            case .card:
                CardView(controller: controller, session: session, app: app, composer: composer)
            case .capsule, .hidden:
                CapsuleView(controller: controller, session: session, app: app, composer: composer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Self.loadFileURLs(from: providers) { composer.add(fileURLs: $0) }
            return true
        }
    }

    static func loadFileURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in completion([url]) }
            }
        }
    }
}

/// The collapsed mini window.
struct CapsuleView: View {
    @ObservedObject var controller: MiniWindowController
    @ObservedObject var session: ChatSession
    @ObservedObject var app: AppModel
    @ObservedObject var composer: ComposerModel

    var body: some View {
        ComposerView(composer: composer, session: session, app: app, actions: controller.capsuleActions)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(WindowDragArea(onDragEnd: controller.panelWasDragged))
            .background(VisualEffectBackground(material: .popover))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

/// The expanded mini window: conversation with header buttons on top and the input pinned to the bottom.
struct CardView: View {
    @ObservedObject var controller: MiniWindowController
    @ObservedObject var session: ChatSession
    @ObservedObject var app: AppModel
    @ObservedObject var composer: ComposerModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                MessageList(session: session, scrollRequest: controller.scrollRequest, topInset: 64, horizontalPadding: 22)
                    // Messages fade out under the header buttons instead of running into them.
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(
                                stops: [.init(color: .clear, location: 0.25), .init(color: .black, location: 1)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 64)
                            Color.black
                        }
                    }
                header
            }
            ComposerView(composer: composer, session: session, app: app, actions: controller.composerActions)
                .frame(height: ComposerLayout.height(for: composer))
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 1)
                )
                .padding(10)
        }
        .background(WindowDragArea(onDragEnd: controller.panelWasDragged))
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            CircleIconButton(systemName: "xmark", label: "Close", filled: true) {
                controller.handle(.closeCard)
            }
            Spacer()
            CircleIconButton(systemName: "square.and.pencil", label: "New Chat", filled: true) {
                controller.handle(.newConversation)
            }
            CircleIconButton(systemName: "arrow.up.left.and.arrow.down.right", label: "Expand to Full Window", filled: true) {
                controller.handle(.expandToFullWindow)
            }
        }
        .padding(12)
        .background(WindowDragArea(onDragEnd: controller.panelWasDragged))
    }
}

struct StopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .textBackgroundColor))
                .frame(width: 11, height: 11)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Stop"))
        .accessibilityLabel(Text("Stop"))
        .accessibilityIdentifier("stop")
    }
}

/// Shows the current model; picking another one applies from the next message and becomes the default.
struct ModelMenu: View {
    @ObservedObject var app: AppModel
    var openSettings: () -> Void

    var body: some View {
        if let current = app.currentModel {
            Menu {
                ForEach(app.providers.filter { !$0.models.isEmpty }) { provider in
                    Section(provider.name) {
                        ForEach(provider.models) { model in
                            Toggle(model.modelID, isOn: Binding(
                                get: { app.currentModel?.id == model.id },
                                set: { isOn in if isOn { app.setDefaultModel(model.id) } }
                            ))
                        }
                    }
                }
            } label: {
                Text(current.modelID)
                    .font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("modelMenu")
        } else {
            Button(action: openSettings) {
                Text("Add Model")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addModel")
        }
    }
}

struct CircleIconButton: View {
    let systemName: String
    let label: LocalizedStringKey
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
        .accessibilityLabel(Text(label))
    }
}
