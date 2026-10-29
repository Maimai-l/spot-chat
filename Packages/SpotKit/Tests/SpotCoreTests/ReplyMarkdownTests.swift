import Foundation
import Testing
@testable import SpotCore

struct ReplyMarkdownTests {
    let zwsp = String(ReplyMarkdown.zeroWidthSpace)

    @Test func plainParagraphsAreUnchanged() {
        let text = "## Steps\n\nFirst paragraph.\n\nSecond paragraph."
        #expect(ReplyMarkdown.prepare(text) == text)
    }

    @Test func aSingleLineBreakStaysALineBreak() {
        #expect(ReplyMarkdown.prepare("one\ntwo\nthree") == "one  \ntwo  \nthree")
    }

    @Test func blocksAfterALineKeepTheirMeaning() {
        let text = "Steps:\n- one\n- two\n1. three\n> quote\n# Title\n---\n| a | b |\n| --- | --- |"
        #expect(ReplyMarkdown.prepare(text) == text)
    }

    @Test func listItemsWithAContinuationLineKeepIt() {
        #expect(ReplyMarkdown.prepare("- first\n  more\n- second") == "- first  \n  more\n- second")
    }

    @Test func setextHeadingsAreKept() {
        #expect(ReplyMarkdown.prepare("Title\n=====\ntext") == "Title\n=====\ntext")
    }

    @Test func codeKeepsItsLines() {
        let text = "```\nlet a = 1\nlet b = 2\n```"
        #expect(ReplyMarkdown.prepare(text) == text)
    }

    @Test func boldEndingInPunctuationBeforeChineseCloses() {
        #expect(ReplyMarkdown.prepare("**注意：**这里") == "**注意：\(zwsp)**这里")
    }

    @Test func boldStartingWithPunctuationAfterChineseOpens() {
        #expect(ReplyMarkdown.prepare("文字**「引用」**后面") == "文字**\(zwsp)「引用」\(zwsp)**后面")
    }

    @Test func ordinaryBoldIsUnchanged() {
        #expect(ReplyMarkdown.prepare("a **bold** word, **加粗**文字") == "a **bold** word, **加粗**文字")
    }

    @Test func markersInCodeSpansAreUnchanged() {
        #expect(ReplyMarkdown.prepare("`**注意：**这里`") == "`**注意：**这里`")
    }

    @Test func streamingClosesAnOpenBoldOrCodeSpan() {
        #expect(ReplyMarkdown.prepare("Some **bold te", isStreaming: true) == "Some **bold te**")
        #expect(ReplyMarkdown.prepare("Run `swift te", isStreaming: true) == "Run `swift te`")
        #expect(ReplyMarkdown.prepare("Done **bold**", isStreaming: true) == "Done **bold**")
        #expect(ReplyMarkdown.prepare("Ends with **", isStreaming: true) == "Ends with **")
        #expect(ReplyMarkdown.prepare("Some **bold te", isStreaming: false) == "Some **bold te")
    }

    @Test func streamingLeavesAnOpenCodeFenceAlone() {
        #expect(ReplyMarkdown.prepare("```swift\nlet **a", isStreaming: true) == "```swift\nlet **a")
    }

    #if canImport(Darwin)
    @Test func lineBreaksSurviveMarkdownParsing() throws {
        let string = try AttributedString(markdown: ReplyMarkdown.prepare("one\ntwo"))
        let text = String(string.characters)
        #expect(text.contains("\n") || text.contains("\u{2028}"), "Got: \(text.debugDescription)")
    }

    @Test func chineseBoldIsParsedAsBold() throws {
        let string = try AttributedString(markdown: ReplyMarkdown.prepare("**注意：**这里"))
        let bold = string.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false }
        #expect(bold.map { String(string[$0.range].characters) }.joined().contains("注意："))
        #expect(!String(string.characters).contains("**"))
    }
    #endif
}
