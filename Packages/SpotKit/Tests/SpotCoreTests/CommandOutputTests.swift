import Testing
@testable import SpotCore

@Suite struct CommandOutputTests {
    @Test func readsTheExitCodeAndDropsNotesForTheModel() {
        let raw = """
        [stderr]
        bash: line 1: /Users/me/escape.txt: Permission denied
        [sandbox: file access denied under workspace-write mode]
        [sandbox: escalation available — retry this exact command once with sandbox_permissions]
        [exit code: 1]
        """
        let result = CommandOutput.read(raw)
        #expect(result.exitCode == 1)
        #expect(result.blockedBySandbox)
        #expect(result.text == "bash: line 1: /Users/me/escape.txt: Permission denied")
    }

    @Test func quietCommandHasNoOutput() {
        let result = CommandOutput.read("(no output)")
        #expect(result.text.isEmpty)
        #expect(result.exitCode == nil)
        #expect(!result.blockedBySandbox)
    }

    @Test func keepsTheEndOfLongOutput() {
        let raw = (1...3000).map { "line \($0)" }.joined(separator: "\n")
        let result = CommandOutput.read(raw)
        #expect(result.text.count == CommandOutput.keptLength + 1)
        #expect(result.text.hasSuffix("line 3000"))
        #expect(result.text.hasPrefix("…"))
    }
}
