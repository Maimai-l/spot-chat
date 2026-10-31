import SwiftUI
import UniformTypeIdentifiers
import SpotCore

struct MiniRootView: View {
    @ObservedObject var controller: MiniWindowController
    @ObservedObject var session: ChatSession
    @ObservedObject var app: AppModel
    @ObservedObject var composer: ComposerModel

    var body: some View {
        ZStack(alignment: .bottom) {
            switch controller.mode {
            case .card:
                CardView(controller: controller, session: session, app: app, composer: composer)
                    .transition(.opacity)
            case .capsule, .hidden:
                CapsuleView(controller: controller, session: session, app: app, composer: composer)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // The window takes the card's size at once and the card fades in over the input, which stays put.
        // Closing the card is immediate, as in Gemini.
        .animation(controller.mode == .card ? .easeOut(duration: 0.18) : nil, value: controller.mode)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Self.loadFileURLs(from: providers) { composer.add(fileURLs: $0, asPaths: session.commandFolder != nil) }
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
        ComposerView(
            composer: composer, session: session, app: app, actions: controller.capsuleActions,
            onTextHeightChange: controller.composerTextHeightChanged
        )
            .background(WindowDragArea(onDragEnd: controller.panelWasDragged))
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            .background(VisualEffectBackground(material: .popover))
            .clipShape(ComposerLayout.shape)
            .rim(ComposerLayout.shape)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
                MessageList(session: session, scrollRequest: controller.scrollRequest, topInset: 72, horizontalPadding: 22)
                    // Messages are hidden behind the header buttons and fade in just below them.
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(
                                stops: [.init(color: .clear, location: 0.6), .init(color: .black, location: 1)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 72)
                            Color.black
                        }
                    }
                header
            }
            // A command that waits for the user is asked about just above the input.
            if let run = session.pendingApproval {
                CommandApprovalCard(run: run, folderName: session.commandFolder?.lastPathComponent ?? "") {
                    session.answerApproval($0)
                }
                .padding(.horizontal, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ComposerView(
                composer: composer, session: session, app: app, actions: controller.composerActions,
                onTextHeightChange: controller.composerTextHeightChanged
            )
                .background(
                    ComposerLayout.shape
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                )
                .rim(ComposerLayout.shape)
                .padding(10)
        }
        .animation(.easeOut(duration: 0.18), value: session.pendingApproval?.id)
        .background(WindowDragArea(onDragEnd: controller.panelWasDragged))
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .rim(RoundedRectangle(cornerRadius: 28, style: .continuous))
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
            CircleIconButton.expand(filled: true) {
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
                .frame(width: 10, height: 10)
                .frame(width: 28, height: 28)
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
/// A light rounded background shows under the pointer, as in Gemini.
/// The model, as a light chip with a chevron like Codex's composer. Its menu lists only models.
/// The model and its reasoning effort in one button, as Gemini picks both from one list: the button shows
/// the model, and its menu lists the models, then the current model's levels, with check marks at the
/// end of the row as in the + menu. Levels and their tooltips are dsh's; each model keeps its own.
struct ModelMenu: View {
    @ObservedObject var app: AppModel
    var openSettings: () -> Void
    var menuWillOpen: () -> Void = {}
    var menuDidClose: () -> Void = {}
    @State private var anchor = MenuAnchor.Reference()

    var body: some View {
        if let current = app.currentModel {
            Button { showMenu(for: current) } label: {
                ComposerChip(verbatim: current.modelID, chevron: false)
            }
            .buttonStyle(.plain)
            .background(MenuAnchor(reference: anchor))
            .fixedSize()
            .accessibilityIdentifier("modelMenu")
        } else {
            Button(action: openSettings) {
                ComposerChip("Add Model", chevron: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addModel")
        }
    }

    private func showMenu(for current: ProviderModel) {
        guard let view = anchor.view else { return }
        let menu = makeMenu(current: current)
        let delegate = ModeMenuDelegate()
        menu.delegate = delegate
        menuWillOpen()
        // Returns once the menu closes.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
        menuDidClose()
        withExtendedLifetime(delegate) {}
    }

    private func makeMenu(current: ProviderModel) -> NSMenu {
        let providers = app.providers.filter { $0.isEnabled && !$0.models.isEmpty }
        let levels = app.supportsEffort(current) ? ThinkingLevel.choices(isDeepSeek: app.isDeepSeek(current)) : []
        let titles = providers.flatMap { $0.models.map(\.modelID) } + levels.map(\.title)
        let width = ModeMenuItem.width(fitting: titles)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = width

        menu.addItem(.sectionHeader(title: String(localized: "Model")))
        for provider in providers {
            for model in provider.models {
                let item = ModeMenuItem(title: model.modelID, symbol: nil, isOn: current.id == model.id, width: width) { [app] in
                    app.setDefaultModel(model.id)
                }
                // With one provider its name would repeat on every row.
                if providers.count > 1 { item.subtitle = provider.name }
                menu.addItem(item)
            }
        }
        // Left out for a model whose service turned effort levels down, as dsh shows none for it.
        if !levels.isEmpty {
            let level = app.thinking(for: current)
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: String(localized: "Effort")))
            for choice in levels {
                let item = ModeMenuItem(title: choice.title, symbol: nil, isOn: level == choice, width: width) { [app] in
                    app.setThinking(choice, for: current)
                }
                item.toolTip = choice.detail
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Manage Models…"), symbol: nil, handler: openSettings))
        return menu
    }
}

/// The view a menu opened from a SwiftUI button pops up from.
struct MenuAnchor: NSViewRepresentable {
    final class Reference {
        weak var view: NSView?
    }

    let reference: Reference

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        reference.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        reference.view = view
    }
}

/// A chip in the input's trailing row: a label and a small chevron, with a pill on hover.
struct ComposerChip: View {
    private let text: Text
    private let secondary: Bool
    private let chevron: Bool
    @State private var hovering = false

    /// A model id is shown as it is, never looked up as a translation.
    init(verbatim: String, secondary: Bool = false, chevron: Bool = true) {
        self.init(text: Text(verbatim: verbatim), secondary: secondary, chevron: chevron)
    }

    init(_ key: LocalizedStringKey, secondary: Bool = false, chevron: Bool = true) {
        self.init(text: Text(key), secondary: secondary, chevron: chevron)
    }

    private init(text: Text, secondary: Bool, chevron: Bool) {
        self.text = text
        self.secondary = secondary
        self.chevron = chevron
    }

    var body: some View {
        HStack(spacing: 4) {
            text
                .font(.system(size: 15, weight: secondary ? .medium : .semibold))
                .foregroundStyle(secondary ? .secondary : .primary)
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct CircleIconButton: View {
    let label: LocalizedStringKey
    var filled = false
    let icon: AnyView
    let action: () -> Void
    @State private var hovering = false

    init(systemName: String, label: LocalizedStringKey, filled: Bool = false, action: @escaping () -> Void) {
        self.init(label: label, filled: filled, icon: Image(systemName: systemName).font(.system(size: 15, weight: .medium)), action: action)
    }

    init(label: LocalizedStringKey, filled: Bool = false, icon: some View, action: @escaping () -> Void) {
        self.label = label
        self.filled = filled
        self.icon = AnyView(icon)
        self.action = action
    }

    /// Corner brackets pointing out, for expanding to the full window.
    static func expand(filled: Bool = false, action: @escaping () -> Void) -> CircleIconButton {
        let size: CGFloat = filled ? 14 : 15
        return CircleIconButton(
            label: "Expand to Full Window",
            filled: filled,
            icon: CornersIcon(inward: false)
                .stroke(style: StrokeStyle(lineWidth: filled ? 1.7 : 2, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size),
            action: action
        )
    }

    var body: some View {
        Button(action: action) {
            icon
                .frame(width: 36, height: 36)
                .background {
                    if filled {
                        Circle()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                            .rim(Circle())
                    }
                    Circle().fill(Color.primary.opacity(hovering ? 0.07 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// Two corner brackets at the top right and bottom left, drawn so the icon is centered exactly.
struct CornersIcon: Shape {
    static let stroke = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)

    var inward: Bool

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * side, y: origin.y + y * side)
        }
        var path = Path()
        let near: CGFloat = 0.06, far: CGFloat = 0.94, arm: CGFloat = 0.44
        if inward {
            // The corners stay apart so the two brackets don't read as a plus sign.
            let corner: CGFloat = 0.38
            path.addLines([point(1 - corner, near), point(1 - corner, corner), point(far, corner)])
            path.addLines([point(near, 1 - corner), point(corner, 1 - corner), point(corner, far)])
        } else {
            path.addLines([point(1 - arm, near), point(far, near), point(far, arm)])
            path.addLines([point(near, 1 - arm), point(near, far), point(arm, far)])
        }
        return path
    }
}

/// A faint circle behind a borderless button while the pointer is over it.
/// A thin light edge around a surface, as Gemini draws its bars, buttons and cards instead of white fills.
struct Rim<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.overlay(
            shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.9), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }
}

extension View {
    func rim<S: InsettableShape>(_ shape: S) -> some View {
        modifier(Rim(shape: shape))
    }
}

struct HoverCircle: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(Circle().fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .onHover { hovering = $0 }
    }
}

extension ThinkingLevel {
    /// Names as in Cherry Studio and dsh.
    var title: String {
        switch self {
        case .automatic: String(localized: "Default")
        case .off: String(localized: "Off")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .max: String(localized: "Max")
        }
    }

    /// dsh's description of each level (packages/llm/llm-deepseek/src/model-info.ts), shown as a tooltip.
    var detail: String? {
        switch self {
        case .off: String(localized: "Use for simple tasks that do not need reasoning.")
        case .low: String(localized: "Prefer for routine or latency-sensitive tasks.")
        case .high: String(localized: "The default balance for most tasks.")
        case .max: String(localized: "Reserve for the hardest quality-first tasks.")
        case .automatic, .medium: nil
        }
    }
}
