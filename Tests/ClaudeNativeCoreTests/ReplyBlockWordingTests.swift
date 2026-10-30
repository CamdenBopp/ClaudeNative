import Foundation
import Testing
@testable import ClaudeNativeCore

/// What VoiceOver says for the blocks inside a reply, pinned word for word.
struct ReplyBlockWordingTests {
    @Test func codeIsNamedByLanguageAndLineCount() {
        let code = "let a = 1\nlet b = 2\nprint(a + b)"
        #expect(ReplyBlockWording.codeLabel(fenceInfo: "swift", code: code, isReceiving: false) == "Swift code, 3 lines")
        #expect(ReplyBlockWording.codeLabel(fenceInfo: "js", code: "x()", isReceiving: false) == "JavaScript code, 1 line")
        #expect(ReplyBlockWording.codeLabel(fenceInfo: nil, code: "x\ny", isReceiving: false) == "Code, 2 lines")
        #expect(ReplyBlockWording.codeLabel(fenceInfo: "", code: "x", isReceiving: false) == "Code, 1 line")
        // Read as written when unknown, and only the info string's first word.
        #expect(ReplyBlockWording.codeLabel(fenceInfo: "zig title=x", code: "x", isReceiving: false) == "zig code, 1 line")
        #expect(ReplyBlockWording.codeLabel(fenceInfo: "Swift", code: "x", isReceiving: false) == "Swift code, 1 line")
    }

    @Test func anOpenFenceSaysItIsStillReceiving() {
        #expect(ReplyBlockWording.codeLabel(fenceInfo: "swift", code: "let a", isReceiving: true)
            == "Swift code, 1 line, still receiving")
        #expect(ReplyBlockWording.codeLabel(fenceInfo: "swift", code: "", isReceiving: true)
            == "Swift code, still receiving")
    }

    @Test func aFinalNewlineEndsALineRatherThanStartingOne() {
        #expect(ReplyBlockWording.lineCount("") == 0)
        #expect(ReplyBlockWording.lineCount("a") == 1)
        #expect(ReplyBlockWording.lineCount("a\n") == 1)
        #expect(ReplyBlockWording.lineCount("a\n\nb") == 3)
    }

    @Test func listItemsKeepTheirNumberAndDropTheBullet() {
        #expect(ReplyBlockWording.listItem("First", number: 1) == "1. First")
        #expect(ReplyBlockWording.listItem("Milk", number: nil) == "Milk")
    }

    @Test func tableRowsCountTheHeaderAsRowOne() {
        #expect(ReplyBlockWording.tableRow(2, cells: ["a", "b"]) == "Row 2: a, b")
        #expect(ReplyBlockWording.tableLabel(rows: 3) == "Table, 3 rows")
        #expect(ReplyBlockWording.tableLabel(rows: 1) == "Table, 1 row")
    }

    @Test func aReplyGroupIsNamedClaudeAndSaysWhenMarked() throws {
        let reply = try #require(FixtureReplayTests.replay("real_text_reply").entries.first { $0.kind == .assistant })
        #expect(RowWording.spokenTitle(of: reply, isMarked: false) == "Claude")
        #expect(RowWording.spokenTitle(of: reply, isMarked: true) == "Claude, marked")
        var speech = RowSpeech(entry: reply, base: nil, isMarked: false, renderedText: "Hello")
        #expect(speech.title == "Claude")
        speech.isMarked = true
        #expect(speech.title == "Claude, marked")
        #expect(speech.value == "Claude, marked: Hello")
    }
}
