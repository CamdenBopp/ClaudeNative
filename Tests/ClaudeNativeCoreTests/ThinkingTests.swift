import Foundation
import Testing
@testable import ClaudeNativeCore

/// Extended thinking, replayed from two real captures (2.1.308, `--effort
/// max`): `real_thinking_summarized` ran with `--thinking-display
/// summarized` and streams the thinking text; `real_thinking_default` ran
/// without it, so every `thinking_delta` is empty and only the signature
/// says Claude thought.
struct ThinkingTests {
    static let summarized = "real_thinking_summarized"
    static let withheld = "real_thinking_default"

    static func thinkingRows(_ transcript: Transcript) -> [TranscriptEntry] {
        transcript.entries.filter { if case .thinking = $0.kind { true } else { false } }
    }

    /// The thinking text the capture's final `assistant` line carries.
    static func finalThinkingText(_ fixture: String) throws -> String {
        let line = try #require(FixtureReplayTests.lines(fixture).first {
            $0.dir == "stdout" && $0.msg["message"]?["content"]?.array?.first?["type"]?.string == "thinking"
        })
        return try #require(line.msg["message"]?["content"]?.array?.first?["thinking"]?.string)
    }

    @Test(arguments: [summarized, withheld])
    func everyLineParsesWithoutDiagnostics(fixture: String) throws {
        #expect(try FixtureReplayTests.replay(fixture).diagnostics == [])
    }

    @Test func summarizedThinkingBecomesOneFinishedRowBeforeTheReply() throws {
        let transcript = try FixtureReplayTests.replay(Self.summarized)
        let rows = Self.thinkingRows(transcript)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.kind == .thinking(isFinished: true))
        let expected = try Self.finalThinkingText(Self.summarized)
        #expect(row.text == expected.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(row.text.hasPrefix("Counting below 1000"))

        let kinds = transcript.entries.map(\.kind)
        #expect(kinds == [.user, .thinking(isFinished: true), .assistant])
    }

    @Test func thinkingStreamsIntoTheRowAndFinishesWhenTheBlockStops() throws {
        var transcript = Transcript()
        var sawPartial = false
        var finishedBeforeReply = false
        for event in try FixtureReplayTests.events(Self.summarized) {
            let changes = transcript.apply(event)
            guard let row = Self.thinkingRows(transcript).first else { continue }
            if case .thinkingDelta = event, row.kind == .thinking(isFinished: false), !row.text.isEmpty {
                #expect(changes == [.updated(id: row.id)])
                sawPartial = true
            }
            if case .textDelta = event, row.kind == .thinking(isFinished: true) {
                finishedBeforeReply = true
            }
        }
        #expect(sawPartial)
        #expect(finishedBeforeReply)
    }

    @Test func withheldThinkingStillShowsThatClaudeThought() throws {
        let events = try FixtureReplayTests.events(Self.withheld)
        #expect(events.contains(.thinkingDelta(index: 0, text: "")))

        let rows = Self.thinkingRows(try FixtureReplayTests.replay(Self.withheld))
        #expect(rows.map(\.kind) == [.thinking(isFinished: true)])
        #expect(rows.first?.text == TranscriptEntry.thinkingPlaceholder)
    }

    /// A restored session never streams: thinking comes only from the
    /// `assistant` line, and must show once, finished.
    @Test(arguments: [summarized, withheld])
    func assistantLinesAloneMakeOneFinishedRow(fixture: String) throws {
        var transcript = Transcript()
        for event in try FixtureReplayTests.events(fixture) {
            if case .assistantMessage = event { transcript.apply(event) }
        }
        let rows = Self.thinkingRows(transcript)
        #expect(rows.map(\.kind) == [.thinking(isFinished: true)])
        let expected = try Self.finalThinkingText(fixture).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(rows.first?.text == (expected.isEmpty ? TranscriptEntry.thinkingPlaceholder : expected))
    }

    @Test func stoppingMidThinkingFinishesTheRow() throws {
        var transcript = Transcript()
        for event in try FixtureReplayTests.events(Self.summarized) {
            if case .contentBlockFinished = event { break }
            transcript.apply(event)
        }
        #expect(Self.thinkingRows(transcript).first?.kind == .thinking(isFinished: false))
        transcript.apply(.turnStopped)
        #expect(Self.thinkingRows(transcript).map(\.kind) == [.thinking(isFinished: true)])
    }

    @Test func redactedThinkingBlockReadsAsThinkingWithNoText() throws {
        let line = try #require(FixtureReplayTests.lines(Self.withheld).first {
            $0.dir == "stdout" && $0.msg["message"]?["content"]?.array?.first?["type"]?.string == "thinking"
        }).msg
        let text = String(decoding: try line.line(), as: UTF8.self)
        let swapped = text.replacingOccurrences(of: "\"type\":\"thinking\"", with: "\"type\":\"redacted_thinking\"")
        #expect(swapped != text)
        let redacted = try JSONValue.parse(Data(swapped.utf8))
        guard case .assistantMessage(_, let blocks)? = try StreamEvent.read(redacted) else {
            Issue.record("assistant line did not parse")
            return
        }
        #expect(blocks == [.thinking("")])
    }

    @Test func messagesRotorSkipsThinking() throws {
        let entries = try FixtureReplayTests.replay(Self.summarized).entries
        var index: Int? = nil
        var visited: [TranscriptEntry.Kind] = []
        while let next = TranscriptNavigation.step(in: entries, kind: .messages, from: index, direction: .next) {
            visited.append(entries[next].kind)
            index = next
        }
        #expect(visited == [.user, .assistant])
    }
}
