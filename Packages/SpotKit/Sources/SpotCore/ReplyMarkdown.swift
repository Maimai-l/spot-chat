import Foundation

/// Adjusts a model's Markdown before Textual renders it, the way chat apps such as Cherry Studio do:
/// - LaTeX is rewritten so it renders (see `MathMarkdown`).
/// - A single line break in a paragraph stays a line break; models use it that way.
/// - Bold and italics work next to punctuation, as in `**注意：**这里`, which CommonMark rejects.
/// - While a reply streams, a `**` or backtick still waiting for its closing half is closed for now,
///   so the text doesn't flicker between raw markers and formatting.
/// Fenced code is left untouched.
public enum ReplyMarkdown {
    public static func prepare(_ markdown: String, isStreaming: Bool = false) -> String {
        var segments = MathMarkdown.segments(markdown)
        for index in segments.indices where !segments[index].isCode {
            var text = MathMarkdown.rewrite(segments[index].text)
            text = fixEmphasisNextToPunctuation(text)
            text = keepLineBreaks(text)
            segments[index].text = text
        }
        var output = segments.map(\.text).joined(separator: "\n")
        if isStreaming, let last = segments.last, !last.isCode {
            output += closingMarkers(forTail: last.text)
        }
        return output
    }

    // MARK: Line breaks

    /// Ends a paragraph line with a hard break when the next line continues the same paragraph.
    static func keepLineBreaks(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return text }
        var output: [String] = []
        for (index, line) in lines.enumerated() {
            var line = String(line)
            if index + 1 < lines.count {
                let next = lines[index + 1]
                if continuesParagraph(line: line[...], next: next) {
                    line += "  "
                }
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private static func continuesParagraph(line: Substring, next: Substring) -> Bool {
        let current = line.trimmingCharacters(in: .whitespaces)
        let following = next.trimmingCharacters(in: .whitespaces)
        guard !current.isEmpty, !following.isEmpty else { return false }
        // Lines that already end in a hard break, headings, tables and rules keep their meaning.
        if line.hasSuffix("  ") || current.hasSuffix("\\") { return false }
        if current.hasPrefix("#") || isThematicBreak(current) || current.allSatisfy({ $0 == "=" }) { return false }
        // Table rows, with or without outer pipes.
        if current.contains("|") || following.contains("|") { return false }
        if startsBlock(following) { return false }
        // A setext heading underline turns the line above into a heading.
        if following.allSatisfy({ $0 == "=" }) || following.allSatisfy({ $0 == "-" }) { return false }
        return true
    }

    private static func startsBlock(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("|") || line.hasPrefix("<") { return true }
        if line.hasPrefix("```") || line.hasPrefix("~~~") || line.hasPrefix("$$") { return true }
        if isThematicBreak(line) { return true }
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return true }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 9 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return true }
        }
        return false
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    // MARK: Emphasis next to punctuation

    /// CommonMark only closes `**` after punctuation when a space or punctuation follows, and only opens it
    /// before punctuation when a space or punctuation precedes. Chinese text has neither, so a zero-width
    /// space is placed between the marker and the punctuation, which satisfies the rule without showing.
    static func fixEmphasisNextToPunctuation(_ text: String) -> String {
        guard text.contains("*") else { return text }
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(c)
                out.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "`" {
                let end = codeSpanEnd(chars, from: i)
                out += String(chars[i..<end])
                i = end
                continue
            }
            guard c == "*" else {
                out.append(c)
                i += 1
                continue
            }
            var end = i
            while end < chars.count, chars[end] == "*" { end += 1 }
            let before: Character? = i > 0 ? chars[i - 1] : nil
            let after: Character? = end < chars.count ? chars[end] : nil
            let run = String(chars[i..<end])
            let beforeIsPunctuation = before.map(isPunctuation) ?? false
            let afterIsPunctuation = after.map(isPunctuation) ?? false
            let beforeIsWord = before.map { !$0.isWhitespace && !isPunctuation($0) } ?? false
            let afterIsWord = after.map { !$0.isWhitespace && !isPunctuation($0) } ?? false
            if beforeIsPunctuation, afterIsWord {
                // Closing after punctuation, e.g. "**注意：**这里".
                out.append(zeroWidthSpace)
                out += run
            } else if beforeIsWord, afterIsPunctuation {
                // Opening before punctuation, e.g. "文字**「引用」**".
                out += run
                out.append(zeroWidthSpace)
            } else {
                out += run
            }
            i = end
        }
        return out
    }

    static let zeroWidthSpace: Character = "\u{200B}"

    private static func isPunctuation(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }
    }

    private static func codeSpanEnd(_ chars: [Character], from start: Int) -> Int {
        var run = 0
        while start + run < chars.count, chars[start + run] == "`" { run += 1 }
        var i = start + run
        while i < chars.count {
            if chars[i] == "`" {
                var length = 0
                while i + length < chars.count, chars[i + length] == "`" { length += 1 }
                if length == run { return i + length }
                i += length
            } else {
                i += 1
            }
        }
        return start + run
    }

    // MARK: Streaming

    /// Markers that close a `**` or a code span left open in the reply's last paragraph.
    static func closingMarkers(forTail text: String) -> String {
        let paragraph = text.components(separatedBy: "\n\n").last ?? text
        let chars = Array(paragraph)
        var strongOpen = false
        var codeOpen = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 2
                continue
            }
            if c == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                if run == 1 { codeOpen.toggle() }
                i += run
                continue
            }
            if !codeOpen, c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "*" { run += 1 }
                if run == 2 { strongOpen.toggle() }
                i += run
                continue
            }
            i += 1
        }
        var closing = ""
        if codeOpen { closing += "`" }
        // A lone "**" at the very end has no text to make bold yet.
        if strongOpen, !paragraph.hasSuffix("**") { closing += "**" }
        return closing
    }
}
