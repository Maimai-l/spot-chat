import Foundation

/// Prepares a reply's Markdown so Textual's math extension renders its LaTeX.
///
/// Textual finds `$…$` and `$$…$$` only after the Markdown is parsed, so without this:
/// - Markdown escapes eat LaTeX backslashes (`\{` becomes `{`, `\(…\)` disappears),
/// - `_` and `*` inside formulas turn into emphasis and split them,
/// - any two dollar signs on a line, like "$5 and $10", become a formula.
///
/// This rewrites `\(…\)`, `\[…\]`, `$…$` and `$$…$$` outside code into `$…$` and `$$…$$` whose contents
/// survive Markdown parsing, and puts every other dollar sign in its own text run so it never pairs up.
/// Inline `$…$` follows Pandoc's rule: no space after the opening dollar, none before the closing one,
/// and no digit right after it.
public enum MathMarkdown {
    /// Markdown for a dollar sign that is not math, on a line with other dollar signs.
    /// Foundation's inline attribute syntax gives it a run of its own, so Textual can't pair it with another.
    public static let isolatedDollar = "^[\\$](inflect: true)"
    /// Markdown for a dollar sign that is not math, alone on its line.
    public static let escapedDollar = "\\$"
    /// Stands in for a literal dollar sign until its line is known.
    private static let placeholder: Character = "\u{E000}"

    public static func prepare(_ markdown: String) -> String {
        guard markdown.contains("$") || markdown.contains("\\(") || markdown.contains("\\[") else {
            return markdown
        }
        // Split into prose and fenced code, keeping every line break.
        var segments: [(isCode: Bool, lines: [Substring])] = []
        var fence: (marker: Character, length: Int)?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = fence {
                segments[segments.count - 1].lines.append(line)
                if let marker = fenceMarker(line), marker.marker == open.marker, marker.length >= open.length,
                   line.drop(while: { $0 == " " }).dropFirst(marker.length).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
            } else if let marker = fenceMarker(line) {
                segments.append((true, [line]))
                fence = marker
            } else if let last = segments.last, !last.isCode {
                segments[segments.count - 1].lines.append(line)
            } else {
                segments.append((false, [line]))
            }
        }
        return segments.map { segment in
            let text = segment.lines.joined(separator: "\n")
            return segment.isCode ? text : rewrite(text)
        }.joined(separator: "\n")
    }

    /// The fence character and its length when the line opens or closes a fenced code block.
    static func fenceMarker(_ line: Substring) -> (marker: Character, length: Int)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let length = rest.prefix(while: { $0 == first }).count
        return length >= 3 ? (first, length) : nil
    }

    /// Rewrites math in text that holds no fenced code.
    static func rewrite(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // Code spans stay as they are.
            if c == "`" {
                let run = countRun(chars, from: i, of: "`")
                if let close = findClosingRun(chars, from: i + run, length: run) {
                    out += String(chars[i..<(close + run)])
                    i = close + run
                } else {
                    out += String(chars[i..<(i + run)])
                    i += run
                }
                continue
            }
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "(" || next == "[" {
                    let closer: Character = next == "(" ? ")" : "]"
                    if let end = findBackslashClose(chars, from: i + 2, closer: closer) {
                        let latex = String(chars[(i + 2)..<end])
                        out += next == "(" ? inline(latex) : display(latex)
                        i = end + 2
                        continue
                    }
                }
                if next == "$" {
                    out.append(placeholder)
                    i += 2
                    continue
                }
                out.append(c)
                out.append(next)
                i += 2
                continue
            }
            if c == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$" {
                    if let end = findDoubleDollar(chars, from: i + 2) {
                        let latex = String(chars[(i + 2)..<end])
                        if !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            out += display(latex)
                            i = end + 2
                            continue
                        }
                    }
                    out.append(placeholder)
                    out.append(placeholder)
                    i += 2
                    continue
                }
                if let end = findInlineClose(chars, from: i + 1) {
                    out += inline(String(chars[(i + 1)..<end]))
                    i = end + 1
                    continue
                }
                out.append(placeholder)
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        return resolvePlaceholders(out)
    }

    /// A literal dollar sign needs its own run only when another dollar sign shares its line.
    static func resolvePlaceholders(_ text: String) -> String {
        guard text.contains(placeholder) else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let dollars = line.filter { $0 == "$" || $0 == placeholder }.count
            let replacement = dollars > 1 ? isolatedDollar : escapedDollar
            return line.map { $0 == placeholder ? replacement : String($0) }.joined()
        }.joined(separator: "\n")
    }

    static func inline(_ latex: String) -> String {
        "$" + escape(latex.trimmingCharacters(in: .whitespacesAndNewlines)) + "$"
    }

    /// Display math is kept on one line, because Textual looks for it within a single run of text.
    static func display(_ latex: String) -> String {
        let flat = latex
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "$$" + escape(flat) + "$$"
    }

    /// Backslash-escapes every ASCII punctuation character, so Markdown hands the LaTeX through unchanged.
    static func escape(_ latex: String) -> String {
        var out = ""
        for c in latex {
            if c.isASCII, c.isPunctuation || c.isSymbol {
                out.append("\\")
            }
            out.append(c)
        }
        return out
    }

    private static func countRun(_ chars: [Character], from start: Int, of char: Character) -> Int {
        var n = 0
        while start + n < chars.count, chars[start + n] == char { n += 1 }
        return n
    }

    private static func findClosingRun(_ chars: [Character], from start: Int, length: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "`" {
                let run = countRun(chars, from: i, of: "`")
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    /// The index of the backslash in `\)` or `\]`.
    private static func findBackslashClose(_ chars: [Character], from start: Int, closer: Character) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "\\" {
                if chars[i + 1] == closer { return i }
                i += 2
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func findDoubleDollar(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if chars[i] == "$", chars[i + 1] == "$" { return i }
            i += 1
        }
        return nil
    }

    /// Pandoc's rule for `$…$`.
    private static func findInlineClose(_ chars: [Character], from start: Int) -> Int? {
        guard start < chars.count, !chars[start].isWhitespace, chars[start] != "$" else { return nil }
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c.isNewline { return nil }
            if c == "\\" {
                i += 2
                continue
            }
            if c == "$" {
                let before = chars[i - 1]
                let after: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if i > start, !before.isWhitespace, !(after?.isNumber ?? false) {
                    return i
                }
                return nil
            }
            i += 1
        }
        return nil
    }
}
