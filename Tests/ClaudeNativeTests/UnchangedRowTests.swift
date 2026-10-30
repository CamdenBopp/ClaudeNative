import AppKit
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Every streaming update shows every row again. A tool row with its
/// output shown formatted all of it each time: 97% of a 112 ms update with
/// 100 long outputs on screen. A row given what it already shows does
/// nothing now.
@MainActor
struct UnchangedRowTests {
    @Test func showingTheSameEntryAgainCostsNothing() {
        var entry = TranscriptEntry(id: "t", kind: .tool(name: "Bash", status: .succeeded), text: "Bash: make")
        entry.output = (0..<2000).map { "line \($0) of a long build log" }.joined(separator: "\n")
        let row = MessageRowView(entry: entry, base: nil, textScale: 1)
        row.showsToolOutput = true
        // Twenty repeats took 24 ms formatting the output each time, and
        // take 0.02 ms skipping it.
        let again = ContinuousClock().measure { for _ in 0..<20 { row.show(entry, base: nil) } }
        #expect(again < .milliseconds(5), "20 repeats took \(again)")
    }

    /// A real change still shows.
    @Test func aChangedEntryStillShows() {
        let entry = TranscriptEntry(id: "a", kind: .user, text: "first")
        let row = MessageRowView(entry: entry, base: nil, textScale: 1)
        var changed = entry
        changed.text = "second"
        row.show(changed, base: nil)
        #expect(row.entry?.text == "second")
    }
}
