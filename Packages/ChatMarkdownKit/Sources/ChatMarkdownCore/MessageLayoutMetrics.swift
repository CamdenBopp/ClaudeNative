import CoreGraphics
import CoreText
import Foundation

/// Shared stacking constants for one message's blocks. The cell container
/// and the off-screen height calculator both consume these through
/// `MessageStacking`, so a message's measured height and its rendered height
/// are equal by construction — the property that makes precomputed list
/// geometry jump-free.
public struct MessageLayoutMetrics: Hashable, Sendable {
    public var blockSpacing: CGFloat = 12
    /// Placeholder height for a block whose first layout has not committed.
    public var estimatedBlockHeight: CGFloat = 22
    public var maxCodeBlockHeight: CGFloat = 300
    /// Per-side vertical padding inside a code block view.
    public var codeVerticalInset: CGFloat = 8
    public var codeFontName: String = "Menlo"
    public var codeFontSize: CGFloat = 13
    /// Line count at (and above) which a code block is exposed to VoiceOver
    /// as a header + chunked-navigation container rather than a single
    /// element. Below this, there's nothing worth paging through — e.g. a
    /// one-line block shouldn't require a two-finger scrub to leave a group.
    public var codeAccessibilityGroupingLineThreshold: Int = 2
    /// List-level: horizontal padding around each message.
    public var horizontalInset: CGFloat = 16
    /// List-level: vertical gap between messages.
    public var interMessageSpacing: CGFloat = 16
    /// List-level: height assumed for a message not yet measured.
    public var estimatedMessageHeight: CGFloat = 60

    public init() {}

    /// Uniform code line height for these font settings. Must agree with
    /// `CodeBlockLayoutEngine.lineHeight` for the same font (cross-checked
    /// by test); creates a CTFont per call, so hoist out of loops.
    public var codeLineHeight: CGFloat {
        let font = CTFontCreateWithName(codeFontName as CFString, codeFontSize, nil)
        return ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }
}

/// The one implementation of message-internal stacking math.
public enum MessageStacking {
    /// The line count `CodeBlockDocument` will report for this rawText's
    /// canonical body (single trailing newline stripped) — lets the height
    /// calculator size code blocks without building a document.
    public static func codeLineCount(forRawText rawText: String) -> Int {
        let body = rawText.hasSuffix("\n") ? String(rawText.dropLast()) : rawText
        guard !body.isEmpty else { return 0 }
        // Byte-wise: this runs against the full code body on every streaming
        // flush of a message being height-watched.
        var count = 1
        for byte in body.utf8 where byte == 0x0A {
            count += 1
        }
        return count
    }

    /// Height of a code block view: natural content height clamped to the
    /// maximum, never shorter than one line. `lineHeight` comes from the
    /// live engine when available (exact) or `metrics.codeLineHeight`.
    public static func codeBlockHeight(
        lineCount: Int,
        lineHeight: CGFloat,
        metrics: MessageLayoutMetrics
    ) -> CGFloat {
        let insets = metrics.codeVerticalInset * 2
        let natural = CGFloat(lineCount) * lineHeight + insets
        return min(max(lineHeight + insets, natural), metrics.maxCodeBlockHeight)
    }
}
