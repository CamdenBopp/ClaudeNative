import Foundation

/// What VoiceOver says about Claude's progress when "Announce What Claude
/// Is Doing" is on, as the Claude app speaks it wherever focus is:
/// "Compacting conversation.", then "Conversation compacted.", and the
/// CLI's line for each step ("Running echo hi."). It follows the
/// conversation whether or not the setting is on, so turning it on
/// mid-turn picks up where things stand.
///
/// The CLI can send the same step's line more than once; a line is said
/// once until a different one, or the turn's end, comes between.
public struct ActivityAnnouncements: Sendable {
    /// Where the setting is saved. Off unless the user turns it on: these
    /// lines interrupt whatever VoiceOver is reading.
    public static let defaultsKey = "announceActivity"

    private var lastStep: String?

    public init() {}

    public mutating func spoken(for event: StreamEvent) -> String? {
        switch event {
        case .activity(.compacting):
            lastStep = nil
            return "Compacting conversation."
        case .activity(.compacted(let succeeded)):
            return succeeded ? "Conversation compacted." : "Couldn't compact the conversation."
        case .activity(.step(let detail)):
            let step = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !step.isEmpty, step != lastStep else { return nil }
            lastStep = step
            return step.last.map { ".!?…".contains($0) } == true ? step : step + "."
        case .turnFinished, .turnStopped:
            lastStep = nil
            return nil
        default:
            return nil
        }
    }
}
