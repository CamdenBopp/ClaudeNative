import Foundation

/// A short tone that says something happened without words. VoiceOver
/// already speaks the details; a cue only marks the moment.
public enum SoundCue: String, CaseIterable, Sendable {
    case toolStarted
    case toolSucceeded
    case toolFailed
    case turnFinished
    case permissionNeeded

    /// What "Play the Sound Cues" says after each tone.
    public var meaning: String {
        switch self {
        case .toolStarted: "That sound means a tool started."
        case .toolSucceeded: "That sound means a tool finished."
        case .toolFailed: "That sound means a tool failed."
        case .turnFinished: "That sound means Claude finished replying."
        case .permissionNeeded: "That sound means Claude needs your permission or an answer."
        }
    }
}

/// Decides which cue, if any, each event from the CLI earns. It follows the
/// conversation whether or not cues are on, so turning them on mid-turn
/// picks up where things stand.
///
/// - A tool's start cue plays once, when its row first appears. Tools read
///   back from a saved conversation never earn one, and neither do their
///   late results.
/// - A tool cut off by Stop doesn't earn a failure cue: the user stopped it,
///   and the app says "Stopped."
/// - Claude finishing plays only when no sent message is still waiting for
///   its reply, the same moment the app says "Claude finished."
/// - The same cue never repeats within `minimumRepeatInterval`, so ten
///   tools starting together make one sound, not ten.
public struct SoundCuePolicy: Sendable {
    /// The shortest gap between two plays of the same cue.
    public static let minimumRepeatInterval: TimeInterval = 0.3
    /// Where the Sound Cues setting is saved. Off unless the user turns it on.
    public static let defaultsKey = "soundCuesEnabled"

    /// Tools whose rows exist, live or restored.
    private var knownToolIDs: Set<String> = []
    /// Tools that started in this process and haven't reported back.
    private var liveToolIDs: Set<String> = []
    private var lastPlayed: [SoundCue: TimeInterval] = [:]
    private var outstandingTurns = 0
    /// Tools the user denied, whose error results stay silent.
    private var deniedToolIDs: Set<String> = []
    /// Set between the user pressing Stop and the turn ending.
    private var stopping = false

    public init() {}

    /// Starts from a conversation read back from disk: its tools already
    /// ran, so they never earn a start cue.
    public init(restoring entries: [TranscriptEntry]) {
        for entry in entries {
            if case .tool = entry.kind { knownToolIDs.insert(Self.toolID(fromRowID: entry.id)) }
        }
    }

    /// The user sent a message; its turn will end with a result.
    public mutating func messageSent() {
        outstandingTurns += 1
    }

    /// A message that `messageSent()` counted never reached the CLI, so no
    /// reply will end it.
    public mutating func sendFailed() {
        outstandingTurns = max(0, outstandingTurns - 1)
    }

    /// The user pressed Stop.
    public mutating func userStopped() {
        stopping = true
    }

    /// The user denied a tool. Its error result is their own doing, so it
    /// doesn't sound as a failure.
    public mutating func userDenied(toolUseID: String?) {
        guard let toolUseID else { return }
        deniedToolIDs.insert(toolUseID)
    }

    /// The cues `event` earns at `time` (seconds on a monotonic clock).
    /// Always empty when `enabled` is false.
    /// `moreToSend`: a message the app is holding goes out as this turn
    /// ends, so a finished turn isn't the end of Claude's work.
    public mutating func cues(for event: StreamEvent, at time: TimeInterval, enabled: Bool, moreToSend: Bool = false) -> [SoundCue] {
        var earned: [SoundCue] = []
        switch event {
        case .assistantMessage(_, let blocks):
            for case .toolUse(let id, _, _) in blocks where !knownToolIDs.contains(id) {
                knownToolIDs.insert(id)
                liveToolIDs.insert(id)
                earned.append(.toolStarted)
            }
        case .toolResult(let id, _, let isError):
            guard liveToolIDs.remove(id) != nil else { break }
            if !isError {
                earned.append(.toolSucceeded)
            } else if !stopping, deniedToolIDs.remove(id) == nil {
                earned.append(.toolFailed)
            }
        case .permissionRequest:
            earned.append(.permissionNeeded)
        case .turnFinished(let isError, _):
            outstandingTurns = max(0, outstandingTurns - 1)
            if outstandingTurns == 0 {
                stopping = false
                // The finished chime means the reply is done. An error turn
                // is announced as an error instead, so it gets no chime.
                // Nor when a held message goes straight out: it chimed as
                // the next reply started.
                if !isError, !moreToSend { earned.append(.turnFinished) }
            }
        case .turnStopped, .processExited:
            // A stop drops queued messages too. No cue: the user did this,
            // and the app says "Stopped." An exit is said by the app too.
            outstandingTurns = 0
            stopping = false
            liveToolIDs.removeAll()
        default:
            break
        }
        guard enabled else { return [] }
        var played: [SoundCue] = []
        for cue in earned where !played.contains(cue) {
            if let last = lastPlayed[cue], time - last < Self.minimumRepeatInterval { continue }
            lastPlayed[cue] = time
            played.append(cue)
        }
        return played
    }

    /// "tool:abc" is the row for tool use "abc" (see `Transcript`).
    private static func toolID(fromRowID rowID: String) -> String {
        rowID.hasPrefix("tool:") ? String(rowID.dropFirst("tool:".count)) : rowID
    }
}
