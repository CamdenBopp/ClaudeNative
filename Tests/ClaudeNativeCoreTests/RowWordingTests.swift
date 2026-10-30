import Foundation
import Testing
@testable import ClaudeNativeCore

/// What VoiceOver says for each transcript row, pinned word for word. Rows
/// come from real captures where one has the kind; the strings are exactly
/// what MessageRowView sets as the row's accessibility value.
@Suite struct RowWordingTests {
    /// The folder `real_permission_allow` ran in. macOS reports it under
    /// /private, so passing the short spelling also checks both are dropped.
    static let allowCaptureFolder = URL(fileURLWithPath: "/var/folders/xx/redacted/T/tmp.DCldecKQhq")

    static func entries(_ fixture: String) throws -> [TranscriptEntry] {
        try FixtureReplayTests.replay(fixture).entries
    }

    /// The first entry matching `isWanted` as it stood at some point during
    /// the replay, for kinds that only exist mid-stream (a running tool, an
    /// unfinished thought).
    static func midStreamEntry(
        _ fixture: String, where isWanted: (TranscriptEntry) -> Bool
    ) throws -> TranscriptEntry? {
        var transcript = Transcript()
        transcript.appendUser("prompt")
        for event in try FixtureReplayTests.events(fixture) {
            transcript.apply(event)
            if let entry = transcript.entries.first(where: isWanted) { return entry }
        }
        return nil
    }

    static func spoken(_ entry: TranscriptEntry, base: URL? = nil, isMarked: Bool = false) -> String {
        RowWording.accessibilityValue(for: entry, base: base, isMarked: isMarked)
    }

    // MARK: Each kind, from real captures

    @Test func userRowSpeaksYouThenTheMessage() throws {
        let user = try #require(Self.entries("real_text_reply").first { $0.kind == .user })
        #expect(Self.spoken(user) == "You: prompt")
        #expect(RowWording.visibleTitle(of: user) == "You")
    }

    @Test func claudeRowSpeaksClaudeThenTheReply() throws {
        let reply = try #require(Self.entries("real_text_reply").first { $0.kind == .assistant })
        #expect(Self.spoken(reply) == "Claude: Hello there, friend!")
        #expect(RowWording.visibleTitle(of: reply) == "Claude")
    }

    @Test func claudeRowSpeaksTheRenderedTextNotTheMarkdown() throws {
        let reply = try #require(Self.entries("real_permission_allow").first { $0.kind == .assistant })
        #expect(reply.text == "Created `hello.txt` in the current directory containing `hi`.")
        let value = RowWording.accessibilityValue(
            for: reply, base: nil, isMarked: false,
            renderedText: "Created hello.txt in the current directory containing hi.")
        #expect(value == "Claude: Created hello.txt in the current directory containing hi.")
    }

    @Test func claudeRowKeepsTheColonEvenWhenTheRenderedTextIsEmpty() throws {
        let reply = try #require(Self.entries("real_text_reply").first { $0.kind == .assistant })
        let value = RowWording.accessibilityValue(for: reply, base: nil, isMarked: false, renderedText: "")
        #expect(value == "Claude: ")
    }

    @Test func noticeRowSpeaksNoticeThenTheNotice() throws {
        let notice = try #require(Self.entries("real_interrupt").first { $0.kind == .notice })
        #expect(Self.spoken(notice) == "Notice: Stopped.")
        #expect(RowWording.visibleTitle(of: notice) == "Notice")
    }

    @Test func finishedToolRowSpeaksDoneAndThePathInsideTheFolder() throws {
        let tool = try #require(Self.entries("real_permission_allow").first {
            $0.kind == .tool(name: "Write", status: .succeeded)
        })
        #expect(Self.spoken(tool, base: Self.allowCaptureFolder) == "Tool, done: Write: hello.txt")
        #expect(RowWording.visibleTitle(of: tool) == "Done")
    }

    @Test func toolRowWithNoFolderSpeaksTheFullPath() throws {
        let tool = try #require(Self.entries("real_permission_allow").first {
            $0.kind == .tool(name: "Write", status: .succeeded)
        })
        #expect(Self.spoken(tool) == "Tool, done: Write: /private/var/folders/xx/redacted/T/tmp.DCldecKQhq/hello.txt")
    }

    @Test func runningToolRowSpeaksRunning() throws {
        let tool = try #require(try Self.midStreamEntry("real_permission_allow") {
            $0.kind == .tool(name: "Write", status: .running)
        })
        #expect(Self.spoken(tool, base: Self.allowCaptureFolder) == "Tool, running: Write: hello.txt")
        #expect(RowWording.visibleTitle(of: tool) == "Running")
    }

    @Test func deniedToolRowSpeaksFailed() throws {
        let tool = try #require(Self.entries("real_permission_deny").first {
            $0.kind == .tool(name: "Write", status: .failed)
        })
        let folder = URL(fileURLWithPath: "/private/var/folders/xx/redacted/T/tmp.7ZEoxNR0ul")
        #expect(Self.spoken(tool, base: folder) == "Tool, failed: Write: hello.txt")
        #expect(RowWording.visibleTitle(of: tool) == "Failed")
    }

    @Test func finishedThoughtSpeaksThoughtThenTheSummary() throws {
        let thought = try #require(Self.entries("real_thinking_summarized").first {
            $0.kind == .thinking(isFinished: true)
        })
        #expect(Self.spoken(thought) == """
            Thought: Counting below 1000: multiples of 7 give 142, multiples of 11 give 90, \
            multiples of 77 give 12. Using inclusion-exclusion for "exactly one divisor," \
            I get 142 + 90 - 2(12) = 208.
            """)
        #expect(RowWording.visibleTitle(of: thought) == "Thought")
    }

    @Test func streamingThoughtSpeaksThinking() throws {
        let empty = try #require(try Self.midStreamEntry("real_thinking_summarized") {
            $0.kind == .thinking(isFinished: false)
        })
        #expect(Self.spoken(empty) == "Thinking")
        #expect(RowWording.visibleTitle(of: empty) == "Thinking")

        let partial = try #require(try Self.midStreamEntry("real_thinking_summarized") {
            $0.kind == .thinking(isFinished: false) && !$0.text.isEmpty
        })
        #expect(Self.spoken(partial) == "Thinking: Counting below")
    }

    /// With the default display the CLI sends no thinking text, so the row
    /// holds the placeholder; speaking it would say "Thought: Thinking".
    @Test(arguments: ["real_thinking_default", "real_permission_allow", "real_interrupt"])
    func withheldThoughtSpeaksOnlyTheTitle(fixture: String) throws {
        let thought = try #require(Self.entries(fixture).first { $0.kind == .thinking(isFinished: true) })
        #expect(thought.text == TranscriptEntry.thinkingPlaceholder)
        #expect(Self.spoken(thought) == "Thought")
        #expect(RowWording.text(of: thought, base: nil) == "")
    }

    // MARK: Rules shared by every kind

    @Test func emptyTextSpeaksTheTitleAlone() {
        let thinking = TranscriptEntry(id: "t", kind: .thinking(isFinished: false), text: "")
        #expect(Self.spoken(thinking) == "Thinking")
    }

    @Test func markedRowSpeaksMarkedAfterTheTitle() throws {
        let entries = try Self.entries("real_permission_allow")
        let user = try #require(entries.first { $0.kind == .user })
        let tool = try #require(entries.first { $0.kind == .tool(name: "Write", status: .succeeded) })
        let thought = try #require(entries.first { $0.kind == .thinking(isFinished: true) })
        let reply = try #require(entries.first { $0.kind == .assistant })
        #expect(Self.spoken(user, isMarked: true) == "You, marked: prompt")
        #expect(Self.spoken(tool, base: Self.allowCaptureFolder, isMarked: true) == "Tool, done, marked: Write: hello.txt")
        #expect(Self.spoken(thought, isMarked: true) == "Thought, marked")
        #expect(RowWording.accessibilityValue(for: reply, base: nil, isMarked: true, renderedText: "Created.")
            == "Claude, marked: Created.")
    }

    // MARK: A row's speech as its parts change

    /// A reply streams with its Markdown half parsed, then gets one final
    /// parse. Relaunching, toggling a mark, or changing the text size all
    /// end with that final parse; it must not drop the mark.
    @Test func finalParseOfAMarkedReplyStillSpeaksMarked() throws {
        let reply = try #require(Self.entries("real_permission_allow").first { $0.kind == .assistant })
        var speech = RowSpeech(
            entry: reply, base: nil, isMarked: true,
            renderedText: "Created hello.txt in the current directory containing")
        speech.renderedText = "Created hello.txt in the current directory containing hi."
        #expect(speech.value == "Claude, marked: Created hello.txt in the current directory containing hi.")
    }

    @Test func markingAFinishedReplyKeepsItsRenderedText() throws {
        let reply = try #require(Self.entries("real_permission_allow").first { $0.kind == .assistant })
        var speech = RowSpeech(
            entry: reply, base: nil, isMarked: false,
            renderedText: "Created hello.txt in the current directory containing hi.")
        speech.isMarked = true
        #expect(speech.value == "Claude, marked: Created hello.txt in the current directory containing hi.")
        speech.isMarked = false
        #expect(speech.value == "Claude: Created hello.txt in the current directory containing hi.")
    }

    @Test func speechMatchesTheWordingForEveryPlainRow() throws {
        let entries = try Self.entries("real_permission_allow").filter { $0.kind != .assistant }
        for entry in entries {
            for isMarked in [false, true] {
                let speech = RowSpeech(entry: entry, base: Self.allowCaptureFolder, isMarked: isMarked)
                #expect(speech.value == Self.spoken(entry, base: Self.allowCaptureFolder, isMarked: isMarked))
            }
        }
    }

}

struct RowSpeechTitleChangeTests {
    let entry = TranscriptEntry(id: "r", kind: .assistant, text: "ping")

    @Test func markingAndStatusChangesAreTitleChanges() {
        let plain = RowSpeech(entry: entry, base: nil, isMarked: false, renderedText: "ping")
        var marked = plain
        marked.isMarked = true
        #expect(marked.titleChanged(from: plain))
        #expect(plain.titleChanged(from: marked))
        let running = RowSpeech(entry: TranscriptEntry(id: "t", kind: .tool(name: "Bash", status: .running), text: "ls"), base: nil, isMarked: false)
        var done = running
        done.entry.kind = .tool(name: "Bash", status: .succeeded)
        #expect(done.titleChanged(from: running))
        let thinking = RowSpeech(entry: TranscriptEntry(id: "k", kind: .thinking(isFinished: false), text: "a"), base: nil, isMarked: false)
        var thought = thinking
        thought.entry.kind = .thinking(isFinished: true)
        #expect(thought.titleChanged(from: thinking))
    }

    @Test func streamingTextAndTheClockAreNot() {
        let early = RowSpeech(entry: entry, base: nil, isMarked: false, renderedText: "pi")
        var later = early
        later.renderedText = "ping"
        later.entry.text = "ping"
        #expect(!later.titleChanged(from: early))
        let running = RowSpeech(entry: TranscriptEntry(id: "t", kind: .tool(name: "Bash", status: .running), text: "ls"), base: nil, isMarked: false, runningSeconds: 4)
        var tick = running
        tick.runningSeconds = 5
        #expect(!tick.titleChanged(from: running))
        #expect(!running.titleChanged(from: nil))
    }
}
