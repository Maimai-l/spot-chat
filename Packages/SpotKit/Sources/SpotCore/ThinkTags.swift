import Foundation

/// Splits a reply that carries its thinking inline, as `<think>…</think>` at the start (DeepSeek R1 on
/// Ollama, SiliconFlow and others), into thinking and text, as Cherry Studio does. Text arrives in
/// pieces, so a tag cut across two pieces is held back until it is complete.
public struct ThinkTagSplitter: Sendable {
    private enum State: Sendable {
        /// Nothing but whitespace yet; the reply may still open with a tag.
        case start
        case thinking
        case text
    }

    private static let open = "<think>"
    private static let close = "</think>"
    private var state = State.start
    private var pending = ""

    public init() {}

    /// The chunks for one more piece of reply text.
    public mutating func feed(_ piece: String) -> [ReplyChunk] {
        pending += piece
        var chunks: [ReplyChunk] = []
        while true {
            switch state {
            case .start:
                let trimmed = pending.drop { $0.isWhitespace }
                if trimmed.hasPrefix(Self.open) {
                    pending = String(trimmed.dropFirst(Self.open.count))
                    state = .thinking
                    continue
                }
                if !trimmed.isEmpty, Self.open.hasPrefix(trimmed) {
                    return chunks  // Possibly the start of the tag.
                }
                if trimmed.isEmpty { return chunks }
                state = .text
                continue
            case .thinking:
                if let range = pending.range(of: Self.close) {
                    let thought = String(pending[..<range.lowerBound])
                    if !thought.isEmpty { chunks.append(.reasoning(thought)) }
                    pending = String(pending[range.upperBound...].drop { $0.isNewline })
                    state = .text
                    continue
                }
                let keep = Self.partialSuffix(of: pending, matching: Self.close)
                let ready = String(pending.dropLast(keep))
                if !ready.isEmpty { chunks.append(.reasoning(ready)) }
                pending = String(pending.suffix(keep))
                return chunks
            case .text:
                if !pending.isEmpty { chunks.append(.text(pending)) }
                pending = ""
                return chunks
            }
        }
    }

    /// Whatever was held back, once the reply has ended.
    public mutating func finish() -> [ReplyChunk] {
        defer { pending = "" }
        guard !pending.isEmpty else { return [] }
        switch state {
        case .thinking: return [.reasoning(pending)]
        case .start, .text: return [.text(pending)]
        }
    }

    /// How many characters at the end of `text` could begin `tag`.
    static func partialSuffix(of text: String, matching tag: String) -> Int {
        for length in stride(from: min(tag.count - 1, text.count), to: 0, by: -1)
        where tag.hasPrefix(text.suffix(length)) {
            return length
        }
        return 0
    }
}
