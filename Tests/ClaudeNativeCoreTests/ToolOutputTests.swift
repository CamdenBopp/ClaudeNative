import Foundation
import Testing
@testable import ClaudeNativeCore

/// A tool row keeps what its tool returned, for Show Tool Output.
struct ToolOutputTests {
    /// Real runs: the Write tool's confirmation and a Bash call with no
    /// output, as the CLI sent them.
    @Test(arguments: [
        ("real_permission_allow", "File created successfully at:"),
        ("real_always_allow", "(Bash completed with no output)"),
    ])
    func aToolRowKeepsWhatItsToolReturned(fixture: String, start: String) throws {
        var transcript = Transcript()
        for event in try FixtureReplayTests.events(fixture) { _ = transcript.apply(event, at: nil) }
        let tool = try #require(transcript.entries.first { if case .tool = $0.kind { true } else { false } })
        let output = try #require(tool.output)
        #expect(output.hasPrefix(start))
        #expect(tool.withToolOutput().text == tool.text + "\n" + output)
        #expect(!tool.text.contains(start))
    }

    /// Long output is cut with a note; nothing at all keeps no output.
    @Test func longOutputIsCutAndEmptyIsDropped() throws {
        let long = String(repeating: "x", count: TranscriptEntry.maxToolOutputLength + 10)
        let kept = try #require(TranscriptEntry.keptOutput(long))
        #expect(kept.hasPrefix(String(repeating: "x", count: TranscriptEntry.maxToolOutputLength) + "\n[Output cut at"))
        #expect(TranscriptEntry.keptOutput("  \n ") == nil)
    }
}
