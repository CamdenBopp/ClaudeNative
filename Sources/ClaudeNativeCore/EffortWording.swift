import Foundation

/// Words for the CLI's effort levels. The CLI names them as identifiers
/// ("xhigh"), which VoiceOver reads as a made-up word.
public enum EffortWording {
    /// "Extra High" for "xhigh"; other levels capitalized.
    public static func title(_ level: String) -> String {
        switch level {
        case "auto": "Automatic"
        case "xhigh": "Extra High"
        default: level.prefix(1).uppercased() + level.dropFirst()
        }
    }
}
