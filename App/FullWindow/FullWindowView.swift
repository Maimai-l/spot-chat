import SwiftUI
import SpotCore

struct FullWindowView: View {
    @ObservedObject var controller: FullWindowController
    @ObservedObject var session: ChatSession
    @ObservedObject var app: AppModel
    @ObservedObject var composer: ComposerModel
    let actions: ComposerActions

    var body: some View {
        NavigationSplitView {
            HistorySidebar(controller: controller, session: session, app: app)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if session.messages.isEmpty {
                    EmptyConversation()
                } else {
                    MessageList(
                        session: session,
                        scrollRequest: controller.scrollRequest,
                        topInset: 12,
                        horizontalPadding: 40,
                        maxContentWidth: 720
                    )
                }
                ComposerView(composer: composer, session: session, app: app, actions: actions)
                    .frame(height: ComposerLayout.height(for: composer))
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 1)
                    )
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 18)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        controller.collapse()
                    } label: {
                        Label("Collapse to Mini Window", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .help(Text("Collapse to Mini Window"))
                    .accessibilityIdentifier("collapseToMini")
                }
            }
        }
    }
}

struct HistorySidebar: View {
    @ObservedObject var controller: FullWindowController
    @ObservedObject var session: ChatSession
    @ObservedObject var app: AppModel
    @FocusState private var renameFocused: Bool

    var body: some View {
        List(selection: Binding(get: { session.topicID }, set: { controller.select($0) })) {
            ForEach(app.topics) { topic in
                row(for: topic)
                    .tag(topic.id)
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("history")
        .safeAreaInset(edge: .top) {
            Button(action: controller.newChat) {
                Label("New Chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .accessibilityIdentifier("newChat")
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: controller.openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(Text("Settings"))
                .accessibilityLabel(Text("Settings"))
                .accessibilityIdentifier("openSettings")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .confirmationDialog(
            Text("Delete \(controller.topicToDelete?.name ?? "")?"),
            isPresented: Binding(get: { controller.topicToDelete != nil }, set: { if !$0 { controller.topicToDelete = nil } }),
            presenting: controller.topicToDelete
        ) { topic in
            Button("Delete", role: .destructive) {
                controller.delete(topic)
            }
        } message: { _ in
            Text("The conversation can't be restored.")
        }
    }

    @ViewBuilder
    private func row(for topic: TopicSummary) -> some View {
        if controller.renamingTopic == topic.id {
            TextField("Name", text: $controller.renameText)
                .focused($renameFocused)
                .onSubmit(controller.commitRename)
                .onAppear { renameFocused = true }
                .onChange(of: renameFocused) {
                    if !renameFocused { controller.commitRename() }
                }
                .accessibilityIdentifier("renameField")
        } else {
            Text(topic.name.isEmpty ? String(localized: "New Chat") : topic.name)
                .lineLimit(1)
                .contextMenu {
                    Button("Rename…") { controller.beginRename(topic) }
                    Divider()
                    Button("Delete…", role: .destructive) { controller.topicToDelete = topic }
                }
                .accessibilityIdentifier("historyItem")
        }
    }
}

struct EmptyConversation: View {
    var body: some View {
        VStack(spacing: 16) {
            SpotMark(size: 40)
            Text("What's on your mind?")
                .font(.system(size: 28, weight: .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
