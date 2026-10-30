import Foundation

/// When the conversation view should see the transcript change.
///
/// Claude's text arrives in deltas of a few words, often dozens a second,
/// and every update the view sees costs it work in proportion to the reply's
/// length. Text growing inside a row that already exists is shown at most
/// once per `currentInterval`, with a trailing update so the last words are
/// never held back for more than that. Anything else (a new row, a finished
/// block, a tool result, the turn ending or being stopped) is shown at once,
/// along with any text still waiting.
///
/// The interval stretches with what an update costs, so updates never take
/// more than `busyShare` of the main thread: a very long reply updates less
/// often instead of leaving no time for VoiceOver, typing, or scrolling.
public struct UpdatePacing: Sendable {
    /// The least time between two updates of streaming text: a few frames,
    /// short enough that text still reads as live.
    public static let interval: TimeInterval = 0.06
    /// The most streaming text waits, however costly updates get.
    public static let longestInterval: TimeInterval = 1
    /// The share of the main thread updates of streaming text may take.
    public static let busyShare = 0.5

    public enum Decision: Sendable, Equatable {
        /// Show the transcript now.
        case publishNow
        /// Show it at this time, unless something shows it sooner.
        case publishAt(TimeInterval)
        /// Nothing new to show, or an update is already on its way.
        case wait
    }

    private var lastPublished: TimeInterval?
    /// The time of the trailing update already asked for, if any.
    public private(set) var scheduled: TimeInterval?
    /// Whether the transcript has changes the view has not seen.
    public private(set) var hasPending = false
    /// The least time between two updates of streaming text, given what
    /// the last one cost.
    public private(set) var currentInterval = interval

    public init() {}

    /// Decides when to show the change `event` made to the transcript at
    /// time `now` (seconds on any steady clock).
    public mutating func changed(
        by event: StreamEvent, changes: [TranscriptChange], at now: TimeInterval
    ) -> Decision {
        let streamsText = switch event {
        case .textDelta, .thinkingDelta: true
        default: false
        }
        if changes.isEmpty {
            // An event that changed nothing still ends a stretch of
            // streaming (the turn finished, a block closed): show what waits.
            return hasPending && !streamsText ? .publishNow : .wait
        }
        let onlyGrows = changes.allSatisfy { if case .updated = $0 { true } else { false } }
        guard streamsText, onlyGrows, let lastPublished else { return .publishNow }
        if now - lastPublished >= currentInterval { return .publishNow }
        hasPending = true
        if scheduled != nil { return .wait }
        let due = lastPublished + currentInterval
        scheduled = due
        return .publishAt(due)
    }

    /// The view was shown the whole transcript at `now`.
    public mutating func published(at now: TimeInterval) {
        lastPublished = now
        hasPending = false
        scheduled = nil
    }

    /// The last update kept the main thread busy for `seconds` (laying out
    /// and drawing the conversation), so the next one waits long enough to
    /// keep updates within `busyShare`.
    public mutating func updateCost(_ seconds: TimeInterval) {
        let needed = seconds / Self.busyShare
        currentInterval = min(Self.longestInterval, max(Self.interval, needed))
    }
}
