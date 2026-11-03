import Foundation
import Testing
import SpotCore
@testable import SpotAgent

/// How a reply that runs commands is built from what dsh reports.
struct ReplyProgressCommandTests {
    func run(_ id: String, state: CommandRun.State = .running) -> CommandRun {
        CommandRun(id: id, tool: .shell, summary: "List the folder", detail: "ls", state: state)
    }

    @Test func textAndThinkingAddUp() {
        var progress = ReplyProgress()
        progress.apply(.thought("Look "))
        progress.apply(.thought("first."))
        progress.apply(.text("Here "))
        progress.apply(.text("it is."))

        #expect(progress.reasoning == "Look first.")
        #expect(progress.text == "Here it is.")
    }

    @Test func aCommandShowsWhereItBeganAndKeepsThatPlaceAsItChanges() {
        var progress = ReplyProgress()
        progress.apply(.text("Listing."))
        progress.apply(.run(run("call_1")))
        progress.apply(.text(" Done."))
        progress.apply(.run(run("call_1", state: .succeeded)))

        #expect(progress.steps.count == 1)
        #expect(progress.steps[0].state == .succeeded)
        #expect(progress.steps[0].textOffset == "Listing.".count)
    }

    @Test func stoppingMarksOnlyTheCommandsStillRunning() {
        var progress = ReplyProgress()
        progress.apply(.run(run("call_1", state: .succeeded)))
        progress.apply(.run(run("call_2")))
        progress.apply(.run(run("call_3", state: .waitingForApproval)))
        progress.stopUnfinishedSteps()

        #expect(progress.steps.map(\.state) == [.succeeded, .stopped, .stopped])
    }
}
