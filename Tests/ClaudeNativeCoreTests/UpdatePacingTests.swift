import Foundation
import Testing
@testable import ClaudeNativeCore

/// The app's loop around UpdatePacing, on a simulated clock: events fold
/// into a live transcript, and the view's copy is replaced only when the
/// pacing says so (or its trailing update comes due).
struct PacedTranscript {
    private(set) var live = Transcript()
    private(set) var shown = Transcript()
    private var pacing = UpdatePacing()
    private var due: TimeInterval?
    /// When the oldest change the view has not seen was made.
    private var waitingSince: TimeInterval?
    private(set) var publishes = 0
    /// What one update costs the view, in seconds per UTF-16 unit of
    /// conversation text, as the transcript view's label pays it.
    var costPerUnit: Double = 0
    /// Main-thread time spent on updates.
    private(set) var busy: TimeInterval = 0
    /// The longest any change waited before the view saw it.
    private(set) var longestWait: TimeInterval = 0

    /// Lets simulated time pass to `now`, firing a trailing update due by then.
    mutating func advance(to now: TimeInterval) {
        if let due, due <= now { publish(at: due) }
    }

    /// Your message shows at once, as AppModel.send shows it.
    mutating func send(_ text: String, at now: TimeInterval) {
        live.appendUser(text, id: "prompt")
        publish(at: now)
    }

    mutating func handle(_ event: StreamEvent, at now: TimeInterval) {
        advance(to: now)
        let changes = live.apply(event)
        if !changes.isEmpty, waitingSince == nil { waitingSince = now }
        switch pacing.changed(by: event, changes: changes, at: now) {
        case .publishNow: publish(at: now)
        case .publishAt(let time): due = time
        case .wait: break
        }
    }

    private mutating func publish(at now: TimeInterval) {
        shown = live
        pacing.published(at: now)
        if costPerUnit > 0 {
            let cost = costPerUnit * Double(live.entries.reduce(0) { $0 + $1.text.utf16.count })
            busy += cost
            pacing.updateCost(cost)
        }
        due = nil
        publishes += 1
        if let waitingSince { longestWait = max(longestWait, now - waitingSince) }
        waitingSince = nil
    }
}

struct UpdatePacingTests {
    static let interval = UpdatePacing.interval

    static func replyText(_ transcript: Transcript) -> String? {
        transcript.entries.last { $0.kind == .assistant }?.text
    }

    /// A long reply arriving as fast as the API bursts it: 7,000 deltas 5 ms
    /// apart. Unpaced, the view would update 7,000 times.
    @Test func longStreamUpdatesTheViewAboutOncePerInterval() throws {
        let text = LongReplyStream.reply(lines: 5_000)
        let events = try LongReplyStream.events(streaming: text)
        var paced = PacedTranscript()
        paced.send("prompt", at: 0)
        let gap = 0.005
        for (index, event) in events.enumerated() {
            paced.handle(event, at: Double(index) * gap)
        }
        let duration = Double(events.count) * gap
        #expect(paced.publishes <= Int(duration / Self.interval) + 10, "\(paced.publishes) updates in \(duration) s")
        #expect(paced.longestWait <= Self.interval + 1e-9)
        // The turn's end shows everything at once; nothing waits for a timer.
        #expect(Self.replyText(paced.shown) == text)
        #expect(paced.shown.entries == paced.live.entries)
    }

    @Test func finishingTheTurnShowsTheLastWordsAtOnce() {
        var paced = PacedTranscript()
        paced.handle(.messageStarted(messageID: "m"), at: 0)
        paced.handle(.textDelta(messageID: nil, text: "Hello"), at: 0.001)
        paced.handle(.textDelta(messageID: nil, text: " there"), at: 0.002)
        paced.handle(.textDelta(messageID: nil, text: ", friend!"), at: 0.003)
        #expect(Self.replyText(paced.shown) == "Hello")
        paced.handle(.turnFinished(isError: false, summary: "Hello there, friend!"), at: 0.004)
        #expect(Self.replyText(paced.shown) == "Hello there, friend!")
    }

    @Test func stoppingShowsTheLastWordsAtOnce() {
        var paced = PacedTranscript()
        paced.handle(.messageStarted(messageID: "m"), at: 0)
        paced.handle(.textDelta(messageID: nil, text: "Working"), at: 0.001)
        paced.handle(.textDelta(messageID: nil, text: " on it"), at: 0.002)
        paced.handle(.turnStopped, at: 0.003)
        #expect(Self.replyText(paced.shown) == "Working on it")
        #expect(paced.shown.entries.last?.text == "Stopped.")
    }

    @Test func aClosedBlockShowsItsThinkingAtOnce() {
        var paced = PacedTranscript()
        paced.handle(.messageStarted(messageID: "m"), at: 0)
        paced.handle(.thinkingStarted(index: 0), at: 0.001)
        paced.handle(.thinkingDelta(index: 0, text: "Let me"), at: 0.002)
        paced.handle(.thinkingDelta(index: 0, text: " check."), at: 0.003)
        paced.handle(.contentBlockFinished(index: 0), at: 0.004)
        #expect(paced.shown.entries.last?.text == "Let me check.")
        #expect(paced.shown.entries.last?.kind == .thinking(isFinished: true))
    }

    /// A new row (here the reply's first words) appears without waiting,
    /// even right after another update.
    @Test func aNewRowAppearsAtOnce() {
        var paced = PacedTranscript()
        paced.handle(.messageStarted(messageID: "m"), at: 0)
        paced.handle(.thinkingStarted(index: 0), at: 0.001)
        paced.handle(.textDelta(messageID: nil, text: "Hi"), at: 0.002)
        #expect(Self.replyText(paced.shown) == "Hi")
    }

    /// The last delta before a pause shows on the trailing update, one
    /// interval after the update before it.
    @Test func aPauseShowsTheWaitingTextOnTheTrailingUpdate() {
        var pacing = UpdatePacing()
        let first = pacing.changed(by: .textDelta(messageID: nil, text: "a"), changes: [.inserted(id: "a")], at: 1.0)
        #expect(first == .publishNow)
        pacing.published(at: 1.0)
        let second = pacing.changed(by: .textDelta(messageID: nil, text: "b"), changes: [.updated(id: "a")], at: 1.01)
        #expect(second == .publishAt(1.0 + Self.interval))
        let third = pacing.changed(by: .textDelta(messageID: nil, text: "c"), changes: [.updated(id: "a")], at: 1.02)
        #expect(third == .wait)
        pacing.published(at: 1.0 + Self.interval)
        let later = pacing.changed(by: .textDelta(messageID: nil, text: "d"), changes: [.updated(id: "a")], at: 1.2)
        #expect(later == .publishNow)
    }

    @Test func costlyUpdatesStretchTheInterval() {
        var pacing = UpdatePacing()
        pacing.published(at: 10)
        pacing.updateCost(0.2)
        #expect(pacing.currentInterval == 0.4)
        let next = pacing.changed(by: .textDelta(messageID: nil, text: "x"), changes: [.updated(id: "a")], at: 10.1)
        #expect(next == .publishAt(10.4))
        pacing.updateCost(5)
        #expect(pacing.currentInterval == UpdatePacing.longestInterval)
        pacing.updateCost(0.001)
        #expect(pacing.currentInterval == Self.interval)
    }

    /// The view's label lays out and draws the whole reply on each update,
    /// so updates cost more as a reply grows: layout alone measured 152 ms
    /// for 55k characters (about 3 ms per thousand). A 5,000-line reply (138k
    /// characters) streamed at the API's pace must still leave the main
    /// thread at least half free, and never hold text back over a second.
    @Test func aLongReplyNeverTakesMoreThanItsShareOfTheMainThread() throws {
        let text = LongReplyStream.reply(lines: 5_000)
        let events = try LongReplyStream.events(streaming: text)
        var paced = PacedTranscript()
        paced.costPerUnit = 3e-6
        paced.send("prompt", at: 0)
        let gap = 0.018
        for (index, event) in events.enumerated() {
            paced.handle(event, at: Double(index + 1) * gap)
        }
        let duration = Double(events.count) * gap
        #expect(paced.busy / duration <= UpdatePacing.busyShare + 0.05, "busy \(paced.busy) s of \(duration) s")
        #expect(paced.longestWait <= UpdatePacing.longestInterval + 1e-9)
        #expect(Self.replyText(paced.shown) == text)
    }

    /// Real captures, replayed with the times the CLI sent each line: at
    /// every event that is not streaming text the view shows exactly the
    /// unpaced transcript, and at the end it always does.
    @Test(arguments: [
        "real_text_reply", "real_permission_allow", "real_permission_deny", "real_interrupt",
        "real_ask_user_question", "real_thinking_summarized", "real_thinking_default", "real_always_allow",
    ])
    func realCapturesEndExactlyAsUnpaced(fixture: String) throws {
        struct Line: Decodable { let dir: String; let t_ms: Double; let msg: JSONValue }
        let url = FixtureReplayTests.fixtures.appending(path: "\(fixture).jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(Line.self, from: Data($0.utf8))
        }
        var paced = PacedTranscript()
        paced.send("prompt", at: 0)
        var unpaced = Transcript()
        unpaced.appendUser("prompt", id: "prompt")
        for line in lines where line.dir == "stdout" {
            guard let event = try StreamEvent.read(JSONValue.parse(line.msg.line())) else { continue }
            paced.handle(event, at: line.t_ms / 1000)
            unpaced.apply(event)
            switch event {
            case .textDelta, .thinkingDelta: break
            default:
                #expect(paced.shown.entries.map(\.text) == unpaced.entries.map(\.text), "after \(event)")
                #expect(paced.shown.entries.map(\.kind) == unpaced.entries.map(\.kind))
            }
        }
        // Notices get a fresh UUID each time, so their ids are left out, and
        // a tool row's start is the clock time each replay saw it.
        func comparable(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
            entries.map {
                var entry = $0.kind == .notice ? TranscriptEntry(id: "notice", kind: .notice, text: $0.text) : $0
                entry.startedAt = nil
                return entry
            }
        }
        #expect(comparable(paced.shown.entries) == comparable(unpaced.entries))
        #expect(paced.longestWait <= Self.interval + 1e-9)
    }
}
