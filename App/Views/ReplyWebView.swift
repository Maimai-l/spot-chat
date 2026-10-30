import AppKit
import SwiftUI
import WebKit

/// A reply's Markdown, rendered by the bundled page in App/Reply (markdown-it, KaTeX, highlight.js).
/// The view is as tall as its content; scrolling is left to the conversation around it.
struct ReplyView: View {
    let id: UUID
    let markdown: String
    let isStreaming: Bool
    @State private var height: CGFloat
    @Environment(\.replyDidResize) private var replyDidResize

    init(id: UUID, markdown: String, isStreaming: Bool) {
        self.id = id
        self.markdown = markdown
        self.isStreaming = isStreaming
        _height = State(initialValue: ReplyHeights.shared[id] ?? 0)
    }

    var body: some View {
        ReplyWebView(markdown: markdown, isStreaming: isStreaming) { newHeight in
            guard abs(newHeight - height) > 0.5 else { return }
            height = newHeight
            ReplyHeights.shared[id] = newHeight
            replyDidResize(id)
        }
        .frame(height: max(height, 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        // Fades in once the page has rendered instead of popping in.
        .opacity(height > 0 ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: height > 0)
    }
}

/// Heights already measured, so a reply scrolled back into view keeps its size while its page reloads.
@MainActor
final class ReplyHeights {
    static let shared = ReplyHeights()
    private var heights: [UUID: CGFloat] = [:]

    subscript(id: UUID) -> CGFloat? {
        get { heights[id] }
        set { heights[id] = newValue }
    }
}

extension EnvironmentValues {
    /// Called with a reply's message ID when its rendered height changes.
    @Entry var replyDidResize: (UUID) -> Void = { _ in }
}

struct ReplyWebView: NSViewRepresentable {
    let markdown: String
    let isStreaming: Bool
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ReplyWKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        let handler = WeakScriptHandler(coordinator)
        for name in Coordinator.messages {
            configuration.userContentController.add(handler, name: name)
        }
        let webView = ReplyWKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = coordinator
        webView.setAccessibilityIdentifier("reply")
        coordinator.webView = webView
        coordinator.onHeight = onHeight
        coordinator.show(markdown, streaming: isStreaming)
        if let page = Coordinator.pageURL {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: ReplyWKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.show(markdown, streaming: isStreaming)
    }

    static func dismantleNSView(_ webView: ReplyWKWebView, coordinator: Coordinator) {
        for name in Coordinator.messages {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messages = ["ready", "height", "copyCode", "openLink"]
        static let pageURL = Bundle.main.url(forResource: "reply", withExtension: "html", subdirectory: "Reply")

        weak var webView: WKWebView?
        var onHeight: (CGFloat) -> Void = { _ in }
        private var isReady = false
        private var shown: (markdown: String, streaming: Bool)?
        private var wanted: (markdown: String, streaming: Bool)?

        /// Sends the text to the page once it has loaded, and only when it changed.
        func show(_ markdown: String, streaming: Bool) {
            wanted = (markdown, streaming)
            flush()
        }

        private func flush() {
            guard isReady, let webView, let wanted, shown?.markdown != wanted.markdown || shown?.streaming != wanted.streaming
            else { return }
            shown = wanted
            let script = "SpotReply.render(\(Self.jsonString(wanted.markdown)), \(wanted.streaming))"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "ready":
                isReady = true
                let labels: [String: String] = [
                    "copy": String(localized: "Copy"),
                    "copied": String(localized: "Copied"),
                    "copyCode": String(localized: "Copy Code"),
                ]
                if let data = try? JSONSerialization.data(withJSONObject: labels),
                   let json = String(data: data, encoding: .utf8) {
                    webView?.evaluateJavaScript("SpotReply.configure(\(json))", completionHandler: nil)
                }
                flush()
            case "height":
                if let height = message.body as? NSNumber {
                    onHeight(CGFloat(height.doubleValue))
                }
            case "copyCode":
                if let code = message.body as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
            case "openLink":
                if let string = message.body as? String, let url = URL(string: string),
                   ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        }

        /// Only the bundled page loads here; anything else opens in the browser or is refused.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            if url?.isFileURL == true, url?.lastPathComponent == "reply.html", navigationAction.navigationType == .other {
                return .allow
            }
            if let url, navigationAction.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }

        /// A crashed web content process leaves an empty view; loading the page again restores the reply.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isReady = false
            shown = nil
            if let page = Self.pageURL {
                webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            }
        }

        private static func jsonString(_ string: String) -> String {
            guard let data = try? JSONEncoder().encode(string), let json = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            return json
        }
    }
}

/// Keeps WebKit from holding the coordinator, which would keep every reply's view alive.
@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Leaves vertical scrolling to the conversation and keeps horizontal scrolling for wide code and tables.
/// Its context menu offers only what makes sense for a reply.
final class ReplyWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let unwanted = ["Reload", "GoBack", "GoForward", "OpenLinkInNewWindow", "DownloadLinkedFile",
                        "OpenImageInNewWindow", "DownloadImage", "OpenFrameInNewWindow", "InspectElement"]
        for item in menu.items where unwanted.contains(where: { item.identifier?.rawValue.contains($0) == true }) {
            menu.removeItem(item)
        }
    }
}
