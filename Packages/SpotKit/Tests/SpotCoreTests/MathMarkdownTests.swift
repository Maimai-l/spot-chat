import Foundation
import Testing
@testable import SpotCore

struct MathMarkdownTests {
    @Test func textWithoutMathIsUnchanged() {
        let text = "## Steps\n\n- **First** item\n\n```sql\nSELECT 1;\n```\n"
        #expect(MathMarkdown.prepare(text) == text)
    }

    @Test func parenthesisDelimitersBecomeInlineMath() {
        #expect(MathMarkdown.prepare("Area is \\(\\pi r^2\\).") == "Area is $\\\\pi r\\^2$.")
    }

    @Test func bracketDelimitersBecomeDisplayMathOnOneLine() {
        let input = "Then\n\\[\n\\frac{a}{b}\n= c\n\\]\ndone"
        #expect(MathMarkdown.prepare(input) == "Then\n$$\\\\frac\\{a\\}\\{b\\} \\= c$$\ndone")
    }

    @Test func doubleDollarDisplayMathIsKept() {
        #expect(MathMarkdown.prepare("$$x_1 + y_2$$") == "$$x\\_1 \\+ y\\_2$$")
    }

    @Test func underscoresInsideInlineMathAreEscaped() {
        #expect(MathMarkdown.prepare("Let $a_1 * b_2$ be") == "Let $a\\_1 \\* b\\_2$ be")
    }

    @Test func pricesOnOneLineAreNotMath() {
        let output = MathMarkdown.prepare("It costs $5 and $10.")
        #expect(output == "It costs \(MathMarkdown.isolatedDollar)5 and \(MathMarkdown.isolatedDollar)10.")
    }

    @Test func aSinglePriceIsEscaped() {
        #expect(MathMarkdown.prepare("Only $5 today") == "Only \\$5 today")
    }

    @Test func aPriceNextToMathIsIsolated() {
        let output = MathMarkdown.prepare("Pay $5 for $x$")
        #expect(output == "Pay \(MathMarkdown.isolatedDollar)5 for $x$")
    }

    @Test func pandocRulesRejectSpacesAndTrailingDigits() {
        let isolated = MathMarkdown.isolatedDollar
        #expect(MathMarkdown.prepare("a $ b$ c") == "a \(isolated) b\(isolated) c")
        #expect(!MathMarkdown.prepare("from $1 to $2").contains("$1 to $"))
    }

    @Test func codeIsLeftAlone() {
        let input = "Use `$x$` or\n\n```\nprice = $5 + $6\n\\(x\\)\n```\nand $y$"
        let output = MathMarkdown.prepare(input)
        #expect(output.hasPrefix("Use `$x$` or\n\n```\nprice = $5 + $6\n\\(x\\)\n```\n"))
        #expect(output.hasSuffix("and $y$"))
    }

    @Test func unclosedDelimitersStayText() {
        #expect(MathMarkdown.prepare("streaming \\[ \\frac{a}") == "streaming \\[ \\frac{a}")
        #expect(MathMarkdown.prepare("streaming $$x + ") .hasPrefix("streaming "))
        #expect(!MathMarkdown.prepare("streaming $$x + ").contains("$$x"))
    }

    #if canImport(Darwin)
    /// Textual's own pattern for inline math.
    static var inlineMath: Regex<(Substring, Substring)> { /\$(?!\$)((?:\\\$|[^$\n])+)\$/ }

    /// Parses like Textual does and returns each run's text.
    static func runs(_ markdown: String) throws -> [String] {
        let string = try AttributedString(markdown: MathMarkdown.prepare(markdown))
        return string.runs.map { String(string[$0.range].characters) }
    }

    @Test func latexSurvivesMarkdownParsing() throws {
        let runs = try Self.runs("Area \\(\\frac{a_1}{b^*}\\) and \\[\\{x \\mid x > 0\\}\\]")
        let text = runs.joined()
        #expect(text.contains("$\\frac{a_1}{b^*}$"))
        #expect(text.contains("$$\\{x \\mid x > 0\\}$$"))
        #expect(runs.contains { $0.contains("$\\frac{a_1}{b^*}$") }, "The formula stays in one run")
    }

    @Test func pricesNeverFormMathInAnyRun() throws {
        for markdown in ["It costs $5 and $10.", "Pay $5 for $x$", "| Plan | Price |\n| --- | --- |\n| Pro | $5 or $9 |"] {
            for run in try Self.runs(markdown) {
                if let match = run.firstMatch(of: Self.inlineMath) {
                    #expect(String(match.1) == "x", "Unexpected math in \(run)")
                }
            }
        }
        #expect(try Self.runs("It costs $5 and $10.").joined() == "It costs $5 and $10.")
    }
    #endif
}
