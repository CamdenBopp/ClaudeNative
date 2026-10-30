import AppKit
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// A page of 200 tool rows with 20,000 characters of output each lays out
/// in a small multiple of the time it takes with Show Tool Output off.
/// Drawing whole outputs took 8.4 s against 0.6 s (14 times); cut at
/// `maxShownOutputLines`, 1.4 s (about 2 times). A ratio, so a slower
/// machine doesn't fail it, and the fastest of a few alternating rounds of
/// each, so a burst of other work during one doesn't: timed once each,
/// under full CPU load the ratio reached 4.6.
@MainActor
struct ToolOutputLayoutTests {
    static let allowedRatio = 4.0
    static let rounds = 3

    @Test func aPageOfLargeOutputsLaysOutInAFewTimesTheTimeWithout() throws {
        var times: [Bool: Duration] = [:]
        let line = String(repeating: "x", count: 79) + "\n"
        let output = String(String(repeating: line, count: 260).prefix(TranscriptEntry.maxToolOutputLength))
        let entries: [TranscriptEntry] = (0..<200).map { number in
            var entry = TranscriptEntry(id: "tool:\(number)", kind: .tool(name: "Bash", status: .succeeded), text: "Bash: build \(number)")
            entry.output = output
            return entry
        }
        for _ in 0..<Self.rounds { for shows in [false, true] {
            let clock = ContinuousClock()
            let start = clock.now
            let view = TranscriptView(transcript: Transcript(restoring: entries), revision: 0, workingDirectory: nil,
                                      isWorking: false, showsToolOutput: shows)
            let (window, host) = AccessibilityHost.window(hosting: view, size: NSSize(width: 700, height: 600))
            host.layoutSubtreeIfNeeded()
            let elapsed = clock.now - start
            times[shows] = min(times[shows] ?? elapsed, elapsed)
            window.close()
        } }
        let off = try #require(times[false]), on = try #require(times[true])
        #expect(on / off < Self.allowedRatio, "on \(on), off \(off)")
    }
}
