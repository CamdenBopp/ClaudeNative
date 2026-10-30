import Testing
@testable import ClaudeNativeCore

struct CaretPositionTests {
    @Test(arguments: ["\n", "\r\n", "\r"])
    func everyLineEndingCounts(ending: String) {
        let text = ["let a = 1", "let b = 2", "print(a)"].joined(separator: ending)
        let thirdLine = ("let a = 1" + ending + "let b = 2" + ending).utf16.count
        let position = CaretPosition.lineAndColumn(in: text, utf16Offset: thirdLine + 3)
        #expect(position.line == 3)
        #expect(position.column == 4)
    }

    @Test func startAndEndOfText() {
        #expect(CaretPosition.lineAndColumn(in: "abc", utf16Offset: 0) == (1, 1))
        #expect(CaretPosition.lineAndColumn(in: "abc\n", utf16Offset: 4) == (2, 1))
        #expect(CaretPosition.lineAndColumn(in: "abc", utf16Offset: 99) == (1, 4))
    }

    /// The gutter numbers paragraphs as NSString's paragraphRange does; a
    /// form feed or U+2028 there doesn't start a line, so the readout said
    /// line 2 beside a gutter showing one.
    @Test func onlyParagraphBreaksStartALine() {
        #expect(CaretPosition.lineAndColumn(in: "a\u{0C}b", utf16Offset: 2) == (1, 3))
        #expect(CaretPosition.lineAndColumn(in: "a\u{2028}b", utf16Offset: 2) == (1, 3))
        #expect(CaretPosition.lineAndColumn(in: "a\u{2029}b", utf16Offset: 2) == (2, 1))
        #expect(CaretPosition.lineAndColumn(in: "a\r\nb", utf16Offset: 3) == (2, 1))
    }
}
