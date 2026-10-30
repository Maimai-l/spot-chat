import Foundation

/// A conversation as Markdown, in the layout of Cherry Studio's topic export
/// (src/renderer/services/ExportService.ts): the title, then a heading for each message, with
/// messages separated by rules.
public enum ConversationExport {
    public static func markdown(title: String, messages: [ChatMessage]) -> String {
        let heading = "# \(title)"
        let shown = messages.filter { $0.role == .user || ($0.status != .error && !$0.text.isEmpty) }
        guard !shown.isEmpty else { return heading }
        let sections = shown.map { message in
            let role = message.role == .user ? "🧑‍💻 User" : "🤖 Assistant"
            var content = message.text
            let files = message.attachments.map(\.displayName)
            if !files.isEmpty {
                content += (content.isEmpty ? "" : "\n\n") + files.map { "[File: \($0)]" }.joined(separator: "\n")
            }
            return ["## \(role)", "", content, ""].joined(separator: "\n")
        }
        return heading + "\n\n" + sections.joined(separator: "\n---\n")
    }

    /// A file name for the export: the title without characters macOS and other systems refuse.
    public static func fileName(for title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Conversation" : String(cleaned.prefix(80))) + ".md"
    }
}

/// Text selected in another app, put into the input as a quote to ask about.
public enum SelectionQuote {
    public static func draft(quoting selection: String) -> String? {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let quoted = text
            .components(separatedBy: .newlines)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return quoted + "\n\n"
    }
}
