import Foundation
import Testing
@testable import ClaudeNativeCore

/// How long a running tool row says it has run, shown and spoken. The
/// running row comes from a real capture, replayed with a fixed clock.
@Suite struct ElapsedWordingTests {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let captureFolder = RowWordingTests.allowCaptureFolder

    /// The Write call from `real_permission_allow`, as it stood while it ran,
    /// with every event stamped `start`.
    static func runningWrite() throws -> TranscriptEntry {
        var transcript = Transcript()
        transcript.appendUser("prompt")
        for event in try FixtureReplayTests.events("real_permission_allow") {
            transcript.apply(event, at: start)
            if let entry = transcript.entries.first(where: { $0.kind == .tool(name: "Write", status: .running) }) {
                return entry
            }
        }
        throw CocoaError(.featureUnsupported)
    }

    static func spoken(_ entry: TranscriptEntry, after seconds: TimeInterval, isMarked: Bool = false) -> String {
        RowSpeech(
            entry: entry, base: captureFolder, isMarked: isMarked,
            runningSeconds: RowWording.runningSeconds(of: entry, at: start.addingTimeInterval(seconds))
        ).value
    }

    // MARK: Spoken and written durations

    @Test(arguments: [
        (1, "1 second"), (40, "40 seconds"), (60, "1 minute"), (65, "1 minute 5 seconds"),
        (121, "2 minutes 1 second"), (3600, "1 hour"), (3720, "1 hour 2 minutes"),
        (7265, "2 hours 1 minute 5 seconds"),
    ])
    func spokenDurationUsesWords(seconds: Int, words: String) {
        #expect(ElapsedWording.spoken(seconds) == words)
    }

    @Test(arguments: [
        (1, "1s"), (40, "40s"), (60, "1m"), (65, "1m 5s"), (3600, "1h"), (3720, "1h 2m"),
    ])
    func visibleDurationIsShort(seconds: Int, text: String) {
        #expect(ElapsedWording.visible(seconds) == text)
    }

    // MARK: How often the shown time moves

    @Test(arguments: [
        (0.0, 0), (0.9, 0), (1.0, 1), (59.99, 59), (60.0, 60), (64.9, 60), (65.0, 65),
        (3599.0, 3595), (3600.0, 3600), (3659.0, 3600), (3660.0, 3660), (-3.0, 0),
    ])
    func shownTimeMovesEverySecondThenInSteps(elapsed: Double, shown: Int) {
        #expect(ElapsedWording.shownSeconds(elapsed) == shown)
    }

    @Test(arguments: [
        (0.0, 1.0), (0.25, 0.75), (58.5, 0.5), (59.0, 1.0), (60.0, 5.0), (61.5, 3.5),
        (3595.0, 5.0), (3600.0, 60.0), (3630.0, 30.0),
    ])
    func timerSleepsUntilTheShownTimeNextMoves(elapsed: Double, wait: Double) {
        #expect(ElapsedWording.untilNextChange(after: elapsed) == wait)
        // Waking then moves the shown time, and waking any sooner would not.
        #expect(ElapsedWording.shownSeconds(elapsed + wait) != ElapsedWording.shownSeconds(elapsed))
        #expect(ElapsedWording.shownSeconds(elapsed + wait - 0.001) == ElapsedWording.shownSeconds(elapsed))
    }

    @Test func timerWakesForTheSoonestRowAndStopsWhenNothingRuns() {
        let now = Self.start.addingTimeInterval(100)
        // One row at 70.4 s (next move at 75 s), one at 2.75 s (next at 3 s).
        let rows = [now.addingTimeInterval(-70.4), now.addingTimeInterval(-2.75)]
        let wait = ElapsedWording.nextTick(startedAt: rows, now: now)
        #expect(wait.map { abs($0 - 0.25) < 1e-6 } == true)
        #expect(ElapsedWording.nextTick(startedAt: [], now: now) == nil)
    }

    // MARK: A running tool row

    @Test func liveToolRowRecordsWhenItStarted() throws {
        #expect(try Self.runningWrite().startedAt == Self.start)
    }

    @Test func runningToolRowSaysHowLongItHasRun() throws {
        let tool = try Self.runningWrite()
        #expect(Self.spoken(tool, after: 40.4) == "Tool, running 40 seconds: Write: hello.txt")
        #expect(Self.spoken(tool, after: 67) == "Tool, running 1 minute 5 seconds: Write: hello.txt")
        #expect(Self.spoken(tool, after: 40, isMarked: true) == "Tool, running 40 seconds, marked: Write: hello.txt")
        let seconds = RowWording.runningSeconds(of: tool, at: Self.start.addingTimeInterval(40))
        #expect(RowWording.visibleTitle(of: tool, runningSeconds: seconds) == "Running  ·  40s")
    }

    @Test func runningToolRowSaysNothingOfTimeInItsFirstSecond() throws {
        let tool = try Self.runningWrite()
        #expect(Self.spoken(tool, after: 0.5) == "Tool, running: Write: hello.txt")
        #expect(RowWording.visibleTitle(of: tool, runningSeconds: 0) == "Running")
    }

    @Test func finishedToolRowIgnoresHowLongItRan() throws {
        var tool = try Self.runningWrite()
        tool.kind = .tool(name: "Write", status: .succeeded)
        #expect(RowWording.runningSeconds(of: tool, at: Self.start.addingTimeInterval(40)) == nil)
        // Even handed a stale time, a finished row reads as before.
        #expect(RowWording.accessibilityValue(for: tool, base: Self.captureFolder, isMarked: false, runningSeconds: 40)
            == "Tool, done: Write: hello.txt")
        #expect(RowWording.visibleTitle(of: tool, runningSeconds: 40) == "Done")
    }

    @Test func restoredToolRowHasNoStartTime() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/history")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        var tools = 0
        for file in files {
            for entry in try SessionHistory.loadSession(fileURL: file).entries {
                guard case .tool = entry.kind else { continue }
                tools += 1
                #expect(entry.startedAt == nil, "\(file.lastPathComponent) \(entry.id)")
            }
        }
        #expect(tools > 0)
    }
}
