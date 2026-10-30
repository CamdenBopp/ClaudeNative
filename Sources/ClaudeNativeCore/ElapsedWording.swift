import Foundation

/// How long a running tool has been going, in the words a row shows and
/// speaks. The row is read on demand and never announced, so the wording
/// only has to be right whenever VoiceOver lands on it.
public enum ElapsedWording {
    /// The shown time moves every second for the first minute, then in
    /// steps of this many seconds, so a long run does not redraw every second.
    public static let minuteStep = 5
    /// After an hour the shown time moves a minute at a time.
    public static let hourStep = 60

    private static let secondsPerMinute = 60
    private static let secondsPerHour = 3600

    /// The whole seconds a row shows after `elapsed` seconds: exact for the
    /// first minute, then rounded down to `minuteStep`, then to `hourStep`.
    public static func shownSeconds(_ elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        let seconds = Int(elapsed.rounded(.down))
        return seconds - seconds % step(at: seconds)
    }

    /// Seconds from `elapsed` until `shownSeconds` next changes, so a timer
    /// can sleep exactly that long.
    public static func untilNextChange(after elapsed: TimeInterval) -> TimeInterval {
        let now = elapsed.isFinite ? max(elapsed, 0) : 0
        var next = Int(now.rounded(.down)) + 1
        let step = step(at: next)
        next += (step - next % step) % step
        return TimeInterval(next) - now
    }

    /// Seconds from `now` until the first of the running tools started at
    /// `startedAt` shows a new time; nil when nothing runs, so the caller
    /// stops its timer.
    public static func nextTick(startedAt: [Date], now: Date) -> TimeInterval? {
        startedAt.map { untilNextChange(after: now.timeIntervalSince($0)) }.min()
    }

    /// "40 seconds", "1 minute 5 seconds", "2 hours 3 minutes": what
    /// VoiceOver says. Zero parts are left out.
    public static func spoken(_ seconds: Int) -> String {
        let (hours, minutes, rest) = parts(seconds)
        let words = [(hours, "hour"), (minutes, "minute"), (rest, "second")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return words.isEmpty ? "0 seconds" : words.joined(separator: " ")
    }

    /// "40s", "1m 5s", "2h 3m": what the row writes beside its status.
    public static func visible(_ seconds: Int) -> String {
        let (hours, minutes, rest) = parts(seconds)
        let words = [(hours, "h"), (minutes, "m"), (rest, "s")]
            .filter { $0.0 > 0 }
            .map { "\($0.0)\($0.1)" }
        return words.isEmpty ? "0s" : words.joined(separator: " ")
    }

    private static func step(at seconds: Int) -> Int {
        if seconds < secondsPerMinute { return 1 }
        return seconds < secondsPerHour ? minuteStep : hourStep
    }

    private static func parts(_ seconds: Int) -> (hours: Int, minutes: Int, seconds: Int) {
        let total = max(seconds, 0)
        return (total / secondsPerHour, total % secondsPerHour / secondsPerMinute, total % secondsPerMinute)
    }
}
