import Testing
@testable import ClaudeNativeCore

struct TerminalTextTests {
    func cleaned(_ chunks: String...) -> String {
        var text = TerminalText()
        chunks.forEach { text.append($0) }
        return text.shown
    }

    @Test func colorsAndTitlesAreRemoved() {
        #expect(cleaned("\u{1B}[1;32mok\u{1B}[0m done\n") == "ok done\n")
        #expect(cleaned("\u{1B}]0;title\u{07}$ ls\r\n") == "$ ls\n")
    }

    /// A progress bar rewrites its line; only the last version is kept.
    @Test func aCarriageReturnRewritesTheLine() {
        #expect(cleaned("10%\r50%\r100%\ndone\n") == "100%\ndone\n")
    }

    @Test func anEscapeSplitAcrossReadsIsStillRemoved() {
        #expect(cleaned("a\u{1B}[3", "1mb\n") == "ab\n")
    }

    @Test func backspaceErasesAndBellIsSilent() {
        #expect(cleaned("abc\u{08}d\u{07}\n") == "abd\n")
    }

    /// zsh's own output around a command, as the panel received it: the
    /// prompt, the typed command echoed a character at a time, then
    /// "\r\r\n" and the result. Each "\r" erased the line before, losing
    /// the prompt and the command.
    @Test func zshsPromptAndCommandSurvive() {
        let shown = cleaned(
            "%" + String(repeating: " ", count: 78) + "\r \r",
            "\rme@Mac IA % \u{1B}[?2004h",
            "e", "c", "h", "o", " hi there",
            "\u{1B}[?2004l\r\r\n",
            "hi there\r\n",
            "%" + String(repeating: " ", count: 78) + "\r \r",
            "\rme@Mac IA % \u{1B}[?2004h"
        )
        #expect(shown == "me@Mac IA % echo hi there\nhi there\nme@Mac IA % ")
    }
}

struct TerminalAnnouncementTests {
    @Test func saysOnlyTheResult() {
        let new = "me@Mac IA % echo hi there\nhi there\nme@Mac IA %"
        #expect(TerminalAnnouncement.newOutput(new, after: "echo hi there") == "hi there")
    }

    /// Output that isn't a command's (a background job, a slow tail) is said as it is.
    @Test func otherOutputIsSaidWhole() {
        #expect(TerminalAnnouncement.newOutput("build finished", after: nil) == "build finished")
        #expect(TerminalAnnouncement.newOutput("build finished", after: "ls") == "build finished")
    }

    /// The prompt was announced before the command was typed, so the new
    /// text starts with the bare command; the next prompt still goes.
    @Test func thePromptAnnouncedBeforeIsLeftOut() {
        let new = "echo hi there\nhi there\nme@Mac IA %"
        #expect(TerminalAnnouncement.newOutput(new, after: "echo hi there", previousLine: "me@Mac IA % ") == "hi there")
    }

    /// Once the cap drops old lines, a position from before still finds
    /// exactly what was written after it.
    @Test func whatWasWrittenSinceAPositionSurvivesTheCap() {
        var output = TerminalText()
        let line = "012345678\n"
        output.append(String(repeating: line, count: TerminalText.maxLength / line.count))
        let before = output.endPosition
        // A short line that makes the cap drop more than it adds.
        output.append("FINAL\n")
        #expect(output.droppedCount > 0)
        #expect(output.since(before).new == "FINAL\n")
        #expect(output.since(before).before.hasSuffix(line))
        #expect(output.since(output.endPosition).new.isEmpty)
    }

    /// An escape string with no end (a binary file cat'ed, `printf '\e]0;x'`)
    /// swallowed everything after it, the prompt included, for good.
    @Test func anUnfinishedOSCDoesntHideLaterOutput() {
        var text = TerminalText()
        text.append("before\n\u{1B}]0;title")
        text.append("next line\nprompt% ")
        #expect(text.shown.hasSuffix("prompt% "), "\(text.shown.debugDescription)")
        #expect(text.shown.hasPrefix("before\n"))
    }

    @Test func aLongUnendedEscapeIsDropped() {
        var text = TerminalText()
        text.append("\u{1B}]" + String(repeating: "x", count: TerminalText.maxEscapeLength + 10))
        text.append("visible")
        #expect(text.shown.hasSuffix("visible"), "\(text.shown.suffix(40).debugDescription)")
    }

    /// DCS bodies are the terminal's business, not text: "1$r0m" was shown.
    @Test func aDCSStringIsNotShown() {
        var text = TerminalText()
        text.append("\u{1B}P1$r0m\u{1B}\\ok")
        #expect(text.shown == "ok")
    }
}
