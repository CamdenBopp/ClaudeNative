import Testing
@testable import ClaudeNative

/// An announcement made as a dialog closes waits until VoiceOver has read
/// where focus landed; posted at once, "Renamed." went unheard.
@MainActor
@Suite(.serialized)
struct AnnouncerTests {
    @Test func announcingAfterADialogWaitsForVoiceOver() async throws {
        var heard: [String] = []
        let token = Announcer.listen { text, _ in heard.append(text) }
        defer { Announcer.stopListening(token) }
        Announcer.announceAfterFocusMove("Renamed.")
        try await Task.sleep(for: Announcer.afterFocusMoveDelay / 2)
        // Other suites announce in parallel; only this line counts.
        #expect(!heard.contains("Renamed."))
        // Polls with a generous ceiling: the hosted suites hold the main
        // actor for seconds at a time, and this announcement needs it.
        let deadline = ContinuousClock.now + Announcer.afterFocusMoveDelay * 30
        while !heard.contains("Renamed."), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(heard.filter { $0 == "Renamed." }.count == 1)
    }
}
