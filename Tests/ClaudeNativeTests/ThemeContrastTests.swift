import AppKit
import Testing
@testable import ClaudeNative
@testable import CodeHighlighting

/// Theme's colours resolved in every appearance, including both Increase
/// Contrast ones, against the window background, measured as WCAG
/// contrast. These are the numbers the Theme comments claim.
@MainActor
@Suite(.serialized) struct ThemeContrastTests {
    /// Light and dark, each with Increase Contrast off and on. AppKit won't
    /// build the high-contrast appearances by name in a test (they come back
    /// as plain Aqua), so Increase Contrast is turned on through Theme's hook.
    nonisolated static let appearances: [String] = ["light", "dark", "light+contrast", "dark+contrast"]

    static func resolved(_ color: NSColor, in look: String) -> NSColor {
        let saved = Theme.increaseContrast
        Theme.increaseContrast = { look.hasSuffix("+contrast") }
        defer { Theme.increaseContrast = saved }
        var result = color
        NSAppearance(named: look.hasPrefix("dark") ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    static func luminance(_ c: NSColor) -> Double {
        func f(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.redComponent) + 0.7152 * f(c.greenComponent) + 0.0722 * f(c.blueComponent)
    }

    /// `top` composited over `bottom` (alpha), as drawn.
    static func over(_ top: NSColor, _ bottom: NSColor) -> NSColor {
        let a = top.alphaComponent
        return NSColor(
            srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
            green: top.greenComponent * a + bottom.greenComponent * (1 - a),
            blue: top.blueComponent * a + bottom.blueComponent * (1 - a), alpha: 1
        )
    }

    static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test(arguments: appearances)
    func quietTextClearsAAOnTheWindowAndOnCards(appearance: String) {
        let window = Self.resolved(.windowBackgroundColor, in: appearance)
        let card = Self.over(Self.resolved(Theme.cardFill, in: appearance), window)
        let quiet = Self.resolved(Theme.quietLabel, in: appearance)
        // 6:1 by the formula, as for links: quiet text renders lighter
        // than its color (the dark system secondary color, 5.0:1 by the
        // formula on the card, measured 3.85:1 on screen).
        #expect(Self.ratio(Self.over(quiet, window), window) >= Self.linkFormulaContrast)
        #expect(Self.ratio(Self.over(quiet, card), card) >= Self.linkFormulaContrast)
    }

    @Test(arguments: appearances)
    func cardEdgesClearTheNonTextMinimum(appearance: String) {
        let window = Self.resolved(.windowBackgroundColor, in: appearance)
        let border = Self.over(Self.resolved(Theme.cardBorder, in: appearance), window)
        #expect(Self.ratio(border, window) >= 3)
    }

    /// The slash list, the @ list and Command-K show which row Return picks
    /// by its highlight alone. The accent tint by itself stood 1.2:1 off the
    /// rows beside it in light, under the 3:1 a state needs (WCAG 1.4.11).
    @Test(arguments: appearances)
    func pickerHighlightEdgeClearsTheNonTextMinimum(appearance: String) {
        let window = Self.resolved(.windowBackgroundColor, in: appearance)
        let card = Self.over(Self.resolved(Theme.cardFill, in: appearance), window)
        for background in [window, card] {
            let edge = Self.over(Self.resolved(Theme.pickerHighlightEdge, in: appearance), background)
            #expect(Self.ratio(edge, background) >= 3, "on \(background)")
        }
    }

    @Test(arguments: appearances)
    func errorTextClearsAA(appearance: String) {
        let window = Self.resolved(.windowBackgroundColor, in: appearance)
        let error = Self.over(Self.resolved(Theme.errorText, in: appearance), window)
        #expect(Self.ratio(error, window) >= 4.5)
    }

    /// Links are thin underlined strokes, which render lighter than their
    /// color: the system link color is 4.9:1 by the formula on the light
    /// window but measured 3.6:1 on screen. Links need 6:1 by the formula.
    @Test(arguments: appearances)
    func linksClearAAAsDrawn(appearance: String) {
        let window = Self.resolved(.windowBackgroundColor, in: appearance)
        let link = Self.over(Self.resolved(Theme.linkText, in: appearance), window)
        #expect(Self.ratio(link, window) >= Self.linkFormulaContrast)
    }

    static let linkFormulaContrast = 6.0
    static let codeFormulaContrast = 5.0

    /// Code in a reply sits on the card fill over the window, not on the
    /// white page the palette first measured against: light keywords,
    /// strings and functions measured 3.3 to 3.5:1 on the card.
    @Test(arguments: appearances)
    func codeTokensClearAAOnTheCard(appearance: String) {
        let window = Self.resolved(.windowBackgroundColor, in: appearance)
        let card = Self.over(Self.resolved(Theme.cardFill, in: appearance), window)
        for token in CodeToken.allCases {
            let color = Self.over(Self.resolved(CodePalette.color(for: token), in: appearance), card)
            // 5:1 by the formula: code renders a little lighter than its
            // color (4.6:1 measured 4.34:1 on screen).
            #expect(Self.ratio(color, card) >= Self.codeFormulaContrast, "\(token) is \(Self.ratio(color, card)):1")
        }
    }

    @Test func increaseContrastMakesEdgesAndQuietTextStronger() {
        for (normal, high) in [("light", "light+contrast"), ("dark", "dark+contrast")] {
            let w1 = Self.resolved(.windowBackgroundColor, in: normal), w2 = Self.resolved(.windowBackgroundColor, in: high)
            let b1 = Self.ratio(Self.over(Self.resolved(Theme.cardBorder, in: normal), w1), w1)
            let b2 = Self.ratio(Self.over(Self.resolved(Theme.cardBorder, in: high), w2), w2)
            #expect(b2 > b1)
            let q1 = Self.ratio(Self.over(Self.resolved(Theme.quietLabel, in: normal), w1), w1)
            let q2 = Self.ratio(Self.over(Self.resolved(Theme.quietLabel, in: high), w2), w2)
            #expect(q2 > q1)
        }
    }
}
