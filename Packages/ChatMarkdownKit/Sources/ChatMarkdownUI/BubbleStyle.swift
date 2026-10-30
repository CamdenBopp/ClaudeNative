#if canImport(UIKit)
import UIKit
import ChatMarkdownCore

/// Visual appearance of one message bubble. Purely presentational chrome drawn
/// around the message content; it never affects the accessibility projection.
///
/// Geometry note: `contentInsets` and `maxWidth` feed the conversation's
/// height/width pipeline (padding adds height; the max width is the wrapping
/// width), so a change here is reflected in both the precomputed list geometry
/// and the rendered cell — heights stay exact.
public struct BubbleStyle {
    /// How wide a bubble may grow. The bubble then *hugs* its content up to
    /// this ceiling — a short message is small, a long one caps here and wraps.
    public enum Width: Hashable, Sendable {
        /// The full available width (viewport minus the list's horizontal inset).
        case fill
        /// A fraction (0...1) of the available width.
        case fraction(CGFloat)
        /// A fixed number of points (clamped to the available width).
        case points(CGFloat)

        public func resolve(available: CGFloat) -> CGFloat {
            switch self {
            case .fill: return available
            case .fraction(let f): return available * max(0, min(1, f))
            case .points(let p): return min(available, max(0, p))
            }
        }
    }

    public enum Alignment: Hashable, Sendable {
        case leading
        case trailing
    }

    public var backgroundColor: UIColor
    /// Text/link tint. `nil` uses the system default (`UIColor.label`).
    public var foregroundColor: UIColor?
    public var cornerRadius: CGFloat
    public var borderWidth: CGFloat
    public var borderColor: UIColor
    public var contentInsets: UIEdgeInsets
    public var maxWidth: Width
    public var alignment: Alignment

    public init(
        backgroundColor: UIColor,
        foregroundColor: UIColor? = nil,
        cornerRadius: CGFloat = 18,
        borderWidth: CGFloat = 0,
        borderColor: UIColor = .separator,
        contentInsets: UIEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14),
        maxWidth: Width = .fill,
        alignment: Alignment = .leading
    ) {
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.contentInsets = contentInsets
        self.maxWidth = maxWidth
        self.alignment = alignment
    }

    var horizontalInsets: CGFloat { contentInsets.left + contentInsets.right }
    var verticalInsets: CGFloat { contentInsets.top + contentInsets.bottom }
}

/// Per-sender bubble appearance. The conversation view resolves a message's
/// sender to one of these styles for both layout and drawing.
public struct BubbleAppearance {
    public var user: BubbleStyle
    public var assistant: BubbleStyle

    public init(user: BubbleStyle, assistant: BubbleStyle) {
        self.user = user
        self.assistant = assistant
    }

    /// Default look: right-aligned tinted user bubbles that hug their content,
    /// left-aligned neutral assistant bubbles that fill the width.
    public init() {
        self.user = BubbleStyle(
            backgroundColor: .systemBlue,
            foregroundColor: .white,
            cornerRadius: 18,
            contentInsets: UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14),
            maxWidth: .fraction(0.82),
            alignment: .trailing
        )
        self.assistant = BubbleStyle(
            backgroundColor: .secondarySystemBackground,
            foregroundColor: nil,
            cornerRadius: 18,
            contentInsets: UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14),
            maxWidth: .fill,
            alignment: .leading
        )
    }

    public func style(for sender: MessageSender) -> BubbleStyle {
        switch sender {
        case .user: return user
        case .assistant: return assistant
        }
    }
}
#endif
