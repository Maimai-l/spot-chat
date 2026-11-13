import ACP
import Foundation
import Testing
import SpotCore
@testable import SpotAgent

/// How a conversation is read back from DeepSeek Harness, and matched with Spot Chat's copy.
struct CommandHistoryTests {
    func updates(_ json: String) throws -> [JsonValue] {
        try JSONDecoder().decode([JsonValue].self, from: Data(json.utf8))
    }

    @Test func questionsRepliesAndCommandsComeBackInOrder() throws {
        let turns = CommandHistory.turns(from: try updates("""
        [
          {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "hello"}},
          {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Hello from dsh."}},
          {"sessionUpdate": "_spotchat_turn_end", "stopReason": "end_turn"},
          {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "列出文件"}},
          {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Look first."}},
          {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "bash", "kind": "other", "status": "in_progress",
           "rawInput": {"description": "List the folder", "command": "ls -a"}},
          {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed", "_spotchat_seconds": 1.5,
           "content": [{"type": "content", "content": {"type": "text", "text": ".\\n..\\n"}}]},
          {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Listed the folder."}},
          {"sessionUpdate": "_spotchat_turn_end", "stopReason": "end_turn"}
        ]
        """))
        #expect(turns.map(\.question) == ["hello", "列出文件"])
        #expect(turns[0].progress.text == "Hello from dsh.")
        #expect(turns[1].progress.reasoning == "Look first.")
        #expect(turns[1].progress.text == "Listed the folder.")
        #expect(turns[1].progress.steps.map(\.detail) == ["ls -a"])
        #expect(turns[1].progress.steps.first?.state == .succeeded)
        // How long it ran is dsh's record of it.
        #expect(turns[1].progress.steps.first?.duration == 1.5)
        #expect(turns.map(\.status) == [.success, .success])
    }

    @Test func aQuestionThatJoinedATurnEndsWithIt() throws {
        let turns = CommandHistory.turns(from: try updates("""
        [
          {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "run something slow"}},
          {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "bash", "kind": "other", "status": "in_progress", "rawInput": {"command": "sleep 60"}},
          {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "hello while busy"}},
          {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Hi."}},
          {"sessionUpdate": "_spotchat_turn_end", "stopReason": "cancelled"}
        ]
        """))
        #expect(turns.map(\.status) == [.paused, .paused])
        #expect(turns[0].progress.steps.first?.state == .stopped)
        // Without dsh's record, no time is shown rather than a wrong one.
        #expect(turns[0].progress.steps.first?.duration == nil)
        #expect(turns[1].progress.text == "Hi.")
    }

    @Test func aTurnStillGoingIsPending() throws {
        let turns = CommandHistory.turns(from: try updates("""
        [{"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "hello"}},
         {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Hel"}}]
        """))
        #expect(turns.first?.status == .pending)
    }

    @Test func anErrorKeepsItsMessage() throws {
        let turns = CommandHistory.turns(from: try updates("""
        [{"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "hello"}},
         {"sessionUpdate": "_spotchat_turn_end", "stopReason": "error", "error": "The model is busy."}]
        """))
        #expect(turns.first?.status == .error)
        #expect(turns.first?.error == "The model is busy.")
    }

    @Test func spotChatsQuestionsAreMatchedInOrder() {
        let turns = ["hello", "list", "hello", "from dsh"].map { CommandHistory.Turn(question: $0) }
        // The second "hello" is the one after "list".
        #expect(CommandHistory.lastMatch(of: ["hello", "list", "hello"], in: turns).map { [$0.question, $0.turn] } == [2, 2])
        // The first, when Spot Chat has only asked once; what dsh asked after is new.
        #expect(CommandHistory.lastMatch(of: ["hello"], in: turns).map { [$0.question, $0.turn] } == [0, 0])
        // A question asked before the session, in plain chat, is passed over.
        #expect(CommandHistory.lastMatch(of: ["what is this", "hello", "list"], in: turns).map { [$0.question, $0.turn] } == [2, 1])
        #expect(CommandHistory.lastMatch(of: ["not there"], in: turns) == nil)
    }
}
