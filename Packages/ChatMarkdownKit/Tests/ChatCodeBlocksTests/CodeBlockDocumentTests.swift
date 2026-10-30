import Testing
@testable import ChatCodeBlocks

struct CodeBlockDocumentTests {
    @Test func appendAcrossLineBoundaries() {
        let document = CodeBlockDocument()

        var delta = document.append("let x")
        #expect(document.lineCount == 1)
        #expect(delta.modifiedLine == nil)
        #expect(delta.appendedLines == 0..<1)

        delta = document.append(" = 1\nprint(x)")
        #expect(document.lineCount == 2)
        #expect(document.line(at: 0) == "let x = 1")
        #expect(document.line(at: 1) == "print(x)")
        #expect(delta.modifiedLine == 0)
        #expect(delta.appendedLines == 1..<2)

        delta = document.append("\n")
        #expect(document.lineCount == 3)
        #expect(delta.modifiedLine == nil)
        #expect(delta.appendedLines == 2..<3)
    }

    @Test func emptyAppendChangesNothing() {
        let document = CodeBlockDocument(text: "a\nb")
        let delta = document.append("")
        #expect(document.lineCount == 2)
        #expect(delta.modifiedLine == nil)
        #expect(delta.appendedLines.isEmpty)
    }

    @Test func textRoundTrips() {
        let document = CodeBlockDocument()
        document.append("func main() {\n")
        document.append("    print(\"hi\")\n}")
        #expect(document.text == "func main() {\n    print(\"hi\")\n}")
    }

    @Test func tenThousandLineAppendStaysLinear() {
        let document = CodeBlockDocument()
        for index in 0..<10_000 {
            document.append("line \(index)\n")
        }
        #expect(document.lineCount == 10_001)
        #expect(document.line(at: 9_999) == "line 9999")
        #expect(document.line(at: 10_000).isEmpty)
    }
}
