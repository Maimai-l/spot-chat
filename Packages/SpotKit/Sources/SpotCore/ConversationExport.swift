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

/// Text selected in another app, asked about. The input holds it apart from the question; the message sent
/// has it as a Markdown quote before the question, which is how it is saved and how the model reads it.
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

    /// The message to send: the selection quoted, then the question. Either may be missing.
    public static func message(quoting selection: String?, question: String) -> String {
        guard let quote = selection.flatMap(draft(quoting:)) else { return question }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return asked.isEmpty ? quote.trimmingCharacters(in: .newlines) : quote + question
    }

    /// A sent message taken apart again: the quote it starts with, if any, and the question after it.
    public static func split(_ message: String) -> (quote: String?, question: String) {
        var lines = message.components(separatedBy: "\n")
        var quoted: [String] = []
        while let line = lines.first, line.hasPrefix(">") {
            var text = line.dropFirst()
            if text.hasPrefix(" ") { text = text.dropFirst() }
            quoted.append(String(text))
            lines.removeFirst()
        }
        let quote = quoted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // A quote counts only when a blank line or the end follows it, as the input writes one.
        guard !quote.isEmpty, lines.first?.trimmingCharacters(in: .whitespaces).isEmpty ?? true else {
            return (nil, message)
        }
        return (quote, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
