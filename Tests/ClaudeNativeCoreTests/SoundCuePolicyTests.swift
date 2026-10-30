import Foundation
import Testing
@testable import ClaudeNativeCore

/// Replays captured CLI sessions, with their real timing, through the sound
/// cue policy the way AppModel drives it: each message the user sent counts
/// as a send, each interrupt as Stop, and each stdout line as events.
struct SoundCuePolicyTests {
    struct TimedLine: Decodable {
        let dir: String
        let t_ms: Double
        let msg: JSONValue
    }

    static func cues(
        replaying name: String,
        into policy: SoundCuePolicy = SoundCuePolicy(),
        enabled: Bool = true
    ) throws -> [SoundCue] {
        var policy = policy
        let text = try String(
            contentsOf: FixtureReplayTests.fixtures.appending(path: "\(name).jsonl"), encoding: .utf8
        )
        var cues: [SoundCue] = []
        for raw in text.split(separator: "\n") {
            let line = try JSONDecoder().decode(TimedLine.self, from: Data(raw.utf8))
            let time = line.t_ms / 1000
            if line.dir == "stdin" {
                switch line.msg["type"]?.string {
                case "user": policy.messageSent()
                case "control_request" where line.msg["request"]?["subtype"]?.string == "interrupt": policy.userStopped()
                case "control_response" where line.msg["response"]?["response"]?["behavior"]?.string == "deny":
                    policy.userDenied(toolUseID: line.msg["response"]?["response"]?["toolUseID"]?.string)
                default: break
                }
                continue
            }
            for event in try StreamEvent.readAll(JSONValue.parse(line.msg.line())) {
                cues += policy.cues(for: event, at: time, enabled: enabled)
            }
        }
        return cues
    }

    @Test(arguments: [
        ("real_text_reply", [SoundCue.turnFinished]),
        ("real_permission_allow", [.toolStarted, .permissionNeeded, .toolSucceeded, .turnFinished]),
        ("real_always_allow", [.toolStarted, .permissionNeeded, .toolSucceeded, .turnFinished]),
        // Deny: the refused tool's error result is the user's own doing.
        ("real_permission_deny", [.toolStarted, .permissionNeeded, .turnFinished]),
        ("real_ask_user_question", [.toolStarted, .permissionNeeded, .toolSucceeded, .turnFinished]),
        // Stop: the cut-off tool's error result and the stopped turn are
        // the user's own doing, so neither sounds.
        ("real_interrupt_running_tool", [.toolStarted]),
        ("real_stop_pending_permission", [.toolStarted, .permissionNeeded]),
        ("real_interrupt", []),
        // Two messages queued: one finish cue, when the second reply ends.
        ("probe_queue", [.turnFinished]),
        // An error turn is announced as an error, without the finished chime.
        ("api_auth_error", []),
    ])
    func realSessionsPlayTheExactCueSequence(fixture: String, expected: [SoundCue]) throws {
        #expect(try Self.cues(replaying: fixture) == expected)
    }

    @Test(arguments: [
        "real_text_reply", "real_permission_allow", "real_always_allow", "real_permission_deny",
        "real_ask_user_question", "real_interrupt_running_tool", "real_stop_pending_permission",
        "probe_queue", "api_auth_error", "multi_turn",
    ])
    func nothingPlaysWithTheSettingOff(fixture: String) throws {
        #expect(try Self.cues(replaying: fixture, enabled: false) == [])
    }

    @Test func aToolRestoredFromASavedSessionNeverSounds() throws {
        let saved = try SessionHistory.loadSession(
            fileURL: SessionHistoryTests.history.appending(path: "permission_allow.jsonl")
        )
        let restored = Transcript(restoring: saved.entries)
        let row = try #require(restored.entry(id: "tool:toolu_mock_ba6bf92c18b347c4"))
        guard case .tool = row.kind else { Issue.record("restored row isn't a tool: \(row.kind)"); return }
        // The same session's stream names the restored tool again.
        let cues = try Self.cues(replaying: "permission_allow", into: SoundCuePolicy(restoring: restored.entries))
        #expect(!cues.contains(.toolStarted))
        #expect(!cues.contains(.toolSucceeded))
        #expect(cues == [.permissionNeeded, .turnFinished])
    }

    @Test func manyToolsStartingAtOnceMakeOneSound() {
        var policy = SoundCuePolicy()
        let three = StreamEvent.assistantMessage(messageID: "m1", blocks: [
            .toolUse(id: "a", name: "Read", input: .object([:])),
            .toolUse(id: "b", name: "Read", input: .object([:])),
            .toolUse(id: "c", name: "Grep", input: .object([:])),
        ])
        #expect(policy.cues(for: three, at: 10, enabled: true) == [.toolStarted])
        let fourth = StreamEvent.assistantMessage(messageID: "m2", blocks: [.toolUse(id: "d", name: "Read", input: .object([:]))])
        #expect(policy.cues(for: fourth, at: 10.1, enabled: true) == [])
        // Results land together too: one success cue.
        #expect(policy.cues(for: .toolResult(toolUseID: "a", text: "", isError: false), at: 10.5, enabled: true) == [.toolSucceeded])
        #expect(policy.cues(for: .toolResult(toolUseID: "b", text: "", isError: false), at: 10.55, enabled: true) == [])
        // A different cue isn't held back by the window.
        #expect(policy.cues(for: .toolResult(toolUseID: "c", text: "", isError: true), at: 10.6, enabled: true) == [.toolFailed])
        // Once the window has passed, the same cue plays again.
        let fifth = StreamEvent.assistantMessage(messageID: "m3", blocks: [.toolUse(id: "e", name: "Read", input: .object([:]))])
        #expect(policy.cues(for: fifth, at: 10.1 + SoundCuePolicy.minimumRepeatInterval + 0.01, enabled: true) == [.toolStarted])
    }

    /// probe_queue's two results land 74 ms apart, inside the repeat
    /// window, so it can't tell "finish once" from "finish per result".
    @Test func aQueuedMessageHoldsTheFinishCueUntilItsReplyEnds() {
        var policy = SoundCuePolicy()
        policy.messageSent()
        policy.messageSent()
        #expect(policy.cues(for: .turnFinished(isError: false, summary: nil), at: 1, enabled: true) == [])
        #expect(policy.cues(for: .turnFinished(isError: false, summary: nil), at: 9, enabled: true) == [.turnFinished])
    }

    @Test func aMessageThatNeverSentDoesntHoldTheFinishCue() {
        var policy = SoundCuePolicy()
        policy.messageSent()
        policy.messageSent()
        policy.sendFailed()
        #expect(policy.cues(for: .turnFinished(isError: false, summary: nil), at: 1, enabled: true) == [.turnFinished])
    }

    @Test func aToolNamedTwiceStartsOnce() {
        var policy = SoundCuePolicy()
        let use = StreamEvent.assistantMessage(messageID: "m1", blocks: [.toolUse(id: "a", name: "Bash", input: .object([:]))])
        #expect(policy.cues(for: use, at: 1, enabled: true) == [.toolStarted])
        #expect(policy.cues(for: use, at: 5, enabled: true) == [])
    }

    @Test func turningCuesOnMidTurnKnowsWhatAlreadyStarted() {
        var policy = SoundCuePolicy()
        policy.messageSent()
        let use = StreamEvent.assistantMessage(messageID: "m1", blocks: [.toolUse(id: "a", name: "Bash", input: .object([:]))])
        #expect(policy.cues(for: use, at: 1, enabled: false) == [])
        #expect(policy.cues(for: use, at: 2, enabled: true) == [])
        #expect(policy.cues(for: .toolResult(toolUseID: "a", text: "", isError: false), at: 3, enabled: true) == [.toolSucceeded])
        #expect(policy.cues(for: .turnFinished(isError: false, summary: nil), at: 4, enabled: true) == [.turnFinished])
    }

    @Test func everyCueHasAMeaningWithoutDashes() {
        for cue in SoundCue.allCases {
            #expect(cue.meaning.hasPrefix("That sound means "))
            #expect(!cue.meaning.contains("\u{2014}"))
        }
    }
}
