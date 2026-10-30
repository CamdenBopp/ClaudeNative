import AppKit
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// View > Show Tool Output draws a tool's output under its summary, and
/// VoiceOver reads it with the row; off, the row is the summary alone.
@MainActor
struct ToolOutputRowTests {
    @Test func individualDisclosureSurvivesUpdatesAndGlobalSettingResetsIt() throws {
        var entry = TranscriptEntry(id: "tool:disclosure", kind: .tool(name: "Bash", status: .running), text: "Bash: make")
        entry.output = "building"
        let row = MessageRowView(entry: entry, base: nil, textScale: 1)
        func action(_ name: String) throws -> NSAccessibilityCustomAction {
            try #require(row.accessibilityCustomActions()?.first { $0.name == name })
        }
        #expect(try action("Show Output").handler?() == true)
        #expect((row.accessibilityValue() as? String)?.contains("building") == true)
        entry.output = "building\nfinished"
        row.show(entry, base: nil)
        row.textScale = 1.3
        #expect((row.accessibilityValue() as? String)?.contains("building\nfinished") == true)
        row.isMarked = true
        row.continuesTurn = true
        let markedText = row.accessibilityValue() as? String ?? ""
        #expect(markedText.components(separatedBy: "building").count == 2)
        #expect(try action("Hide Output").handler?() == true)
        #expect((row.accessibilityValue() as? String)?.contains("building") == false)
        row.showsToolOutput = true
        #expect((row.accessibilityValue() as? String)?.contains("building\nfinished") == true)
        #expect(row.accessibilityRole() == .staticText)
    }

    @Test func theRowShowsItsOutputOnlyWhenAsked() {
        var entry = TranscriptEntry(id: "tool:1", kind: .tool(name: "Bash", status: .succeeded), text: "Bash: ls beds")
        entry.output = "beds: tomatoes, beans"
        let row = MessageRowView(entry: entry, base: nil, textScale: TextScale.standard.factor)
        row.show(entry, base: nil)
        func spoken() -> String { (row.accessibilityValue() as? String) ?? row.accessibilityLabel() ?? "" }
        #expect(spoken() == "Tool, done: Bash: ls beds")
        row.showsToolOutput = true
        #expect(spoken() == "Tool, done: Bash: ls beds\nbeds: tomatoes, beans")
        row.showsToolOutput = false
        #expect(spoken() == "Tool, done: Bash: ls beds")
    }

    /// A new text size redraws the row from the transcript's entry; drawn
    /// from the shown one, the output appeared twice.
    @Test func aNewTextSizeKeepsOneCopyOfTheOutput() {
        var entry = TranscriptEntry(id: "tool:1", kind: .tool(name: "Bash", status: .succeeded), text: "Bash: ls beds")
        entry.output = "beds: tomatoes, beans"
        let row = MessageRowView(entry: entry, base: nil, textScale: TextScale.standard.factor)
        row.show(entry, base: nil)
        row.showsToolOutput = true
        row.textScale = TextScale.standard.factor * 1.3
        #expect((row.accessibilityValue() as? String) == "Tool, done: Bash: ls beds\nbeds: tomatoes, beans")
    }

    /// The output is drawn monospaced, so a listing's columns line up.
    @Test func theOutputIsMonospaced() throws {
        let text = MessageRowView.toolText(summary: "Bash: ls -l", output: "-rw-r--r--  1 me  staff  12 notes.txt", scale: 1)
        let outputStart = ("Bash: ls -l\n" as NSString).length
        let summaryFont = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let outputFont = try #require(text.attribute(.font, at: outputStart, effectiveRange: nil) as? NSFont)
        #expect(!summaryFont.isFixedPitch)
        #expect(outputFont.isFixedPitch)
    }

    /// A long output shows its first lines and how many more, and Copy
    /// Output copies all of it.
    @Test func longOutputIsCutOnTheRowAndCopiedWhole() throws {
        let lines = (1...30).map { "line \($0)" }
        var entry = TranscriptEntry(id: "tool:2", kind: .tool(name: "Bash", status: .succeeded), text: "Bash: make")
        entry.output = lines.joined(separator: "\n")
        let shown = try #require(entry.shownOutput)
        #expect(shown.hasPrefix("line 1\n"))
        #expect(shown.contains("line \(TranscriptEntry.maxShownOutputLines)\n"))
        #expect(!shown.contains("line \(TranscriptEntry.maxShownOutputLines + 1)\n"))
        #expect(shown.hasSuffix("[\(30 - TranscriptEntry.maxShownOutputLines) more lines. Copy Output copies it all.]"))
        let row = MessageRowView(entry: entry, base: nil, textScale: TextScale.standard.factor)
        row.show(entry, base: nil)
        let board = NSPasteboard.withUniqueName()
        Clipboard.board = board
        defer { Clipboard.board = .general; board.releaseGlobally() }
        let copy = try #require((row.accessibilityCustomActions() ?? []).first { $0.name == "Copy Output" })
        _ = copy.handler?()
        #expect(board.string(forType: .string) == entry.output)
    }
}
