import ACP
import ACPModel
import Foundation
import SpotCore

/// A conversation as DeepSeek Harness keeps it, for one that runs commands there: what Spot Chat asked and
/// what was asked in dsh's own interface, each with its reply. Spot Chat rebuilds its copy from it, since
/// the session in dsh is where the conversation goes on.
public enum CommandHistory {
    public struct Turn: Equatable, Sendable {
        public var question: String
        public var progress = ReplyProgress()
        /// ACP's stop reason, `end_turn`, `cancelled` or `error`; nil while the turn goes on.
        public var stopReason: String?
        public var error: String?

        public init(question: String, progress: ReplyProgress = ReplyProgress(), stopReason: String? = nil, error: String? = nil) {
            self.question = question
            self.progress = progress
            self.stopReason = stopReason
            self.error = error
        }

        /// How the reply is saved.
        public var status: MessageStatus {
            switch stopReason {
            case nil: return .pending
            case "cancelled": return .paused
            case "error": return .error
            default: return .success
            }
        }
    }

    /// The questions and replies in the updates Spot Chat's plugin returns for a session: ACP session updates
    /// as a client following it would have seen them, with `_spotchat_turn_end` where each turn ended. A
    /// question sent while a turn ran joins that turn, so one end can close several questions.
    static func turns(from updates: [JsonValue]) -> [Turn] {
        var turns: [Turn] = []
        var runs: [String: CommandRun] = [:]
        var unended: [Int] = []
        for value in updates {
            guard case let .object(object) = value, case let .string(kind)? = object["sessionUpdate"] else { continue }
            if kind == "_spotchat_turn_end" {
                var stopReason = "end_turn"
                if case let .string(reason)? = object["stopReason"] { stopReason = reason }
                var error: String?
                if case let .string(message)? = object["error"] { error = message }
                for index in unended {
                    turns[index].stopReason = stopReason
                    turns[index].error = error
                    if stopReason != "end_turn" { turns[index].progress.stopUnfinishedSteps() }
                }
                unended = []
                continue
            }
            if kind == "user_message_chunk" {
                var text = ""
                if case let .object(content)? = object["content"], case let .string(value)? = content["text"] { text = value }
                turns.append(Turn(question: text))
                unended.append(turns.count - 1)
                continue
            }
            guard !turns.isEmpty,
                  let data = try? JSONEncoder().encode(value),
                  let update = try? JSONDecoder().decode(SessionUpdate.self, from: data),
                  var event = CommandAgent.event(for: update, runs: &runs, cancelling: false)
            else { continue }
            // How long a command ran is what dsh recorded; reading the history now says nothing about it.
            if case var .run(run) = event {
                switch object["_spotchat_seconds"] {
                case let .double(seconds)?: run.duration = seconds
                case let .int(seconds)?: run.duration = TimeInterval(seconds)
                default: run.duration = nil
                }
                runs[run.id]?.duration = run.duration
                event = .run(run)
            }
            turns[turns.count - 1].progress.apply(event)
        }
        return turns
    }

    /// Spot Chat's questions, `known`, found among `turns` with the questions matched in order: for each one
    /// found, its index there and the turn's. A known question with no match, such as one asked before
    /// commands ran in DeepSeek Harness, is passed over.
    public static func matches(of known: [String], in turns: [Turn]) -> [(question: Int, turn: Int)] {
        var next = 0
        var found: [(question: Int, turn: Int)] = []
        for (position, question) in known.enumerated() where next < turns.count {
            if let index = turns[next...].firstIndex(where: { $0.question == question }) {
                found.append((position, index))
                next = index + 1
            }
        }
        return found
    }

    /// The last of `known` found among `turns`; nil when none is.
    public static func lastMatch(of known: [String], in turns: [Turn]) -> (question: Int, turn: Int)? {
        matches(of: known, in: turns).last
    }
}
