import Foundation

/// How much bigger than the system's text size the conversation is drawn,
/// stepped like Safari's and Messages' Command-Plus and Command-Minus.
public struct TextScale: Equatable, Sendable {
    /// The sizes the commands step through, as multiples of the system size.
    public static let steps: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2, 2.5, 3]
    public static let standard = TextScale(1)
    /// Where the scale is saved between launches.
    public static let defaultsKey = "transcriptTextScale"

    public let factor: Double

    /// The nearest step to `factor`, so a hand-edited or stale saved value
    /// still lands on one the commands can step from.
    public init(_ factor: Double) {
        self.factor = Self.steps.min { abs($0 - factor) < abs($1 - factor) } ?? 1
    }

    private var index: Int { Self.steps.firstIndex(of: factor) ?? 1 }

    public var bigger: TextScale? {
        index + 1 < Self.steps.count ? TextScale(Self.steps[index + 1]) : nil
    }

    public var smaller: TextScale? {
        index > 0 ? TextScale(Self.steps[index - 1]) : nil
    }

    /// What VoiceOver says after a change: "Text size 130 percent".
    public var spoken: String {
        "Text size \(Int((factor * 100).rounded())) percent"
    }
}
