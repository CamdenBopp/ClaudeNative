import AppKit
import SwiftUI

/// The app's one table of visual constants. Every radius, spacing and fill
/// the transcript, composer and side panel use comes from here, so they stay
/// consistent and can be tuned in one place. Colors are semantic system
/// colors, so light, dark and Increase Contrast all work.
enum Theme {
    enum Radius {
        /// Image previews inside a chip.
        static let thumbnail: CGFloat = 4
        /// Small chips: attachments, tags.
        static let chip: CGFloat = 8
        /// Cards: code blocks, tool rows.
        static let card: CGFloat = 12
        /// The tint behind your own messages.
        static let bubble: CGFloat = 16
        /// The composer card.
        static let composer: CGFloat = 20
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
    }

    /// Behind a notice that needs attention, such as a file that changed on
    /// disk while you were editing it.
    static let noticeFill = Color.yellow.opacity(0.2)

    /// Behind the highlighted row of a picker the keyboard drives from
    /// elsewhere, such as the slash command list.
    static let pickerHighlight = Color.accentColor.opacity(0.25)
    /// The edge of that row, what tells it from its neighbours: the tint
    /// alone stood 1.2:1 off them in light. Label-colored, so it clears 3:1
    /// whatever accent color is chosen.
    static let pickerHighlightEdge = NSColor.labelColor

    /// How wide a line of conversation text may run, in multiples of the
    /// body font's size: about 70 characters, the comfortable reading width
    /// the reference apps use (720 to 768 points at 13-point text). Derived
    /// from the font so it grows with the text size.
    static let readingWidthInEms: CGFloat = 55

    /// The reading width for the conversation's text at `scale`, so bigger
    /// text keeps about the same number of characters to a line.
    static func readingWidth(scale: Double) -> CGFloat {
        conversationTextSize(.body, scale: scale) * readingWidthInEms
    }

    /// The point size of a text style in the conversation: the system's
    /// size times the user's Command-Plus/Command-Minus scale.
    static func conversationTextSize(_ style: NSFont.TextStyle, scale: Double) -> CGFloat {
        (NSFont.preferredFont(forTextStyle: style).pointSize * scale).rounded()
    }

    /// Your messages sit in a tint at most this share of the column wide.
    static let bubbleWidthShare: CGFloat = 0.8

    /// How strongly cards and bubbles stand off the window, as the opacity
    /// of black (light) or white (dark) laid over it. The system's
    /// quaternary fill measured 1.12:1 against the dark window on screen,
    /// which a low-vision reader can't see. The fill only tints; the border
    /// below carries the edge.
    static let cardFillLightOpacity: CGFloat = 0.08
    static let cardFillDarkOpacity: CGFloat = 0.09
    /// Stronger under Increase Contrast.
    static let cardFillHighContrastOpacity: CGFloat = 0.14

    /// How opaque a card's or field's border is, so the edge measures at
    /// least 3:1 against the window, the WCAG minimum for a boundary you
    /// need to see. 45% black measured 2.9:1 on the light window.
    static let borderLightOpacity: CGFloat = 0.5
    static let borderDarkOpacity: CGFloat = 0.5

    /// Which of the four looks a colour is drawn for.
    enum Look {
        case light, dark, highContrastLight, highContrastDark
    }

    /// Whether Increase Contrast is on. Read from the system as well as
    /// from the appearance, so the stronger colours don't depend on AppKit
    /// naming the appearance, and so tests can turn it on.
    nonisolated(unsafe) static var increaseContrast: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static func look(of appearance: NSAppearance) -> Look {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        let isHigh = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua || increaseContrast()
        switch (isDark, isHigh) {
        case (false, false): return .light
        case (true, false): return .dark
        case (false, true): return .highContrastLight
        case (true, true): return .highContrastDark
        }
    }

    private static func overlay(light: CGFloat, dark: CGFloat, highContrast: CGFloat) -> (NSAppearance) -> NSColor {
        { appearance in
            switch look(of: appearance) {
            case .light: NSColor.black.withAlphaComponent(light)
            case .dark: NSColor.white.withAlphaComponent(dark)
            case .highContrastLight: NSColor.black.withAlphaComponent(highContrast)
            case .highContrastDark: NSColor.white.withAlphaComponent(highContrast)
            }
        }
    }

    /// The tint behind your messages and the fill behind tool rows and code
    /// cards. Text on it keeps its contrast: it shifts the window's
    /// brightness by a few percent.
    static let cardFill = NSColor(
        name: "ClaudeNativeCardFill",
        dynamicProvider: overlay(light: cardFillLightOpacity, dark: cardFillDarkOpacity, highContrast: cardFillHighContrastOpacity)
    )
    static var bubbleFill: NSColor { cardFill }

    /// The edge around cards, bubbles and the message field.
    static let cardBorder = NSColor(name: "ClaudeNativeCardBorder") { appearance in
        switch look(of: appearance) {
        case .light: NSColor.black.withAlphaComponent(borderLightOpacity)
        case .dark: NSColor.white.withAlphaComponent(borderDarkOpacity)
        case .highContrastLight, .highContrastDark: .labelColor
        }
    }

    /// The empty part of the composer's context ring. It reads against the
    /// card at 3:1 or better, and the label-colored arc against it: the card
    /// border's 50% white left the arc under 3:1 in dark.
    static let contextRingTrack = NSColor(name: "ClaudeNativeContextRingTrack") { appearance in
        switch look(of: appearance) {
        case .light, .highContrastLight: NSColor.black.withAlphaComponent(contextRingTrackLightOpacity)
        case .dark, .highContrastDark: NSColor.white.withAlphaComponent(contextRingTrackDarkOpacity)
        }
    }
    static let contextRingTrackLightOpacity: CGFloat = 0.5
    static let contextRingTrackDarkOpacity: CGFloat = 0.4

    /// Text for errors. The system red is 3.6:1 on the light window; this
    /// darker red clears 4.5:1 there, and dark keeps the system red, which
    /// already does (4.9:1).
    static let errorText = NSColor(name: "ClaudeNativeErrorText") { appearance in
        switch look(of: appearance) {
        case .dark, .highContrastDark: .systemRed
        case .light, .highContrastLight: NSColor(srgbRed: 0.75, green: 0.08, blue: 0.10, alpha: 1)
        }
    }

    /// Links in replies. The system link color is 4.9:1 by the formula on
    /// the light window, but underlined strokes render lighter: 3.6:1
    /// measured on screen, 4.6:1 in dark. These clear 6:1 by the formula.
    static let linkText = NSColor(name: "ClaudeNativeLinkText") { appearance in
        switch look(of: appearance) {
        case .light, .highContrastLight: NSColor(srgbRed: 0, green: 0.30, blue: 0.70, alpha: 1)
        case .dark, .highContrastDark: NSColor(srgbRed: 0.45, green: 0.70, blue: 1, alpha: 1)
        }
    }

    /// How opaque quiet text is in the light appearance. The system's
    /// secondary label color is 50% black, under 4:1 on the window and card
    /// fills. At 60% the message placeholder's strokes rendered at only
    /// 4.34:1 on the white composer (darkest pixel, 2x capture); 66%
    /// renders at 5.4:1.
    static let quietTextLightOpacity: CGFloat = 0.66

    /// How opaque quiet text is in the dark appearance. The system's
    /// secondary label color rendered at 3.85:1 on the dark tool card
    /// (darkest pixel, 2x capture).
    static let quietTextDarkOpacity: CGFloat = 0.7

    /// Quieter text: author labels, tool status and summaries. Black or
    /// white at the opacities above, which render at 4.5:1 or better on
    /// the window and on cards, and full label color under Increase
    /// Contrast.
    static let quietLabel = NSColor(name: "ClaudeNativeQuietLabel") { appearance in
        switch look(of: appearance) {
        case .light: return NSColor.black.withAlphaComponent(quietTextLightOpacity)
        case .dark: return NSColor.white.withAlphaComponent(quietTextDarkOpacity)
        case .highContrastLight, .highContrastDark: return .labelColor
        }
    }

    /// How long after a view appears to move VoiceOver to it. Asked for
    /// sooner, before the element is in the accessibility tree, the move is
    /// dropped.
    static let accessibilityFocusDelay: Duration = .milliseconds(300)

    /// The least width and height of an icon-only button's target. The
    /// window's toolbar buttons measured 31 points wide; this is the
    /// smaller square for buttons inside the window's content.
    static let iconButtonSize: CGFloat = 24

    /// How thick a hairline border is drawn.
    static let hairlineWidth: CGFloat = 1
    /// A focused field's edge, about the system focus ring's width.
    static let focusBorderWidth: CGFloat = 2

    /// The composer card's fill: the opaque fill text fields sit on, so the
    /// card needs no material and reads the same under Reduce Transparency.
    static var composerFill: NSColor { .controlBackgroundColor }
}
