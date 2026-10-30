import Foundation
import Testing
@testable import ClaudeNativeCore

/// The Claude app speaks "Compacting conversation" and each step as it
/// starts, wherever focus is. These lines were dropped: only `init` was
/// read from the CLI's `system` lines.
struct ActivityAnnouncementsTests {
    /// Captured from CLI 2.1.310: a reply, `/compact`, then a request that
    /// ran `echo hi`.
    @Test func aRealCompactionAndStepAreSpokenInOrder() throws {
        var announcements = ActivityAnnouncements()
        let spoken = try FixtureReplayTests.events("real_compact_and_step").compactMap { announcements.spoken(for: $0) }
        #expect(spoken == ["Compacting conversation.", "Conversation compacted.", "Running echo hi."])
    }

    @Test func theRealLinesReadAsActivities() throws {
        let activities = try FixtureReplayTests.events("real_compact_and_step").compactMap { event -> Activity? in
            if case .activity(let activity) = event { activity } else { nil }
        }
        #expect(activities == [.compacting, .compacted(succeeded: true), .step("Running echo hi")])
    }

    /// The same step's line twice is said once, until the turn ends.
    @Test func aRepeatedStepIsSaidOnce() {
        var announcements = ActivityAnnouncements()
        let events: [StreamEvent] = [
            .activity(.step("Running tests")), .activity(.step("Running tests")),
            .activity(.step("Reading Package.swift")), .turnFinished(isError: false, summary: nil),
            .activity(.step("Reading Package.swift")),
        ]
        #expect(events.compactMap { announcements.spoken(for: $0) } == [
            "Running tests.", "Reading Package.swift.", "Reading Package.swift.",
        ])
    }

    @Test func aFailedCompactionSaysSo() {
        var announcements = ActivityAnnouncements()
        let line = JSONValue.object([
            "type": .string("system"), "subtype": .string("status"),
            "status": .null, "compact_result": .string("failed"),
        ])
        let event = try? StreamEvent.read(line)
        #expect(event.flatMap { announcements.spoken(for: $0) } == "Couldn't compact the conversation.")
    }
}
