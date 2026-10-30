import AppKit

/// Token colors for code. Each starts from a system color and is darkened (on
/// light backgrounds) or lightened (on dark ones) only as far as needed to
/// reach WCAG AA contrast against `textBackgroundColor` in the appearance
/// being drawn. The adjustment runs at resolve time, so it also follows
/// Increase Contrast and any future change to the system colors.
enum CodePalette {
    /// WCAG 2.x AA for normal-size text.
    static let minimumContrast: CGFloat = 4.5
    /// What the adjustment aims for, above the minimum because code
    /// renders a little lighter than its color: aimed at 4.6:1, functions
    /// measured 4.34:1 on screen.
    static let targetContrast: CGFloat = 5
    /// Bisection steps when blending toward black or white; 2^-16 is far below
    /// one 8-bit color step.
    private static let blendSearchSteps = 16

    static let plainText = accessible(.labelColor, named: "plainText")

    /// One dynamic color per token kind, built once.
    static let tokenColors: [CodeToken: NSColor] = Dictionary(
        uniqueKeysWithValues: CodeToken.allCases.map { ($0, accessible($0.baseColor, named: "\($0)")) }
    )

    static func color(for token: CodeToken) -> NSColor {
        tokenColors[token] ?? plainText
    }

    /// A dynamic color that resolves `base` in the drawing appearance and
    /// then pulls it toward black or white until it clears `targetContrast`.
    static func accessible(_ base: NSColor, named name: String) -> NSColor {
        NSColor(name: NSColor.Name("CodeHighlighting.\(name)")) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                let page = SRGB(NSColor.textBackgroundColor) ?? SRGB.white
                // Code blocks in chat sit on a light wash of the label color;
                // a token must clear that background too.
                let wash = SRGB(NSColor.labelColor.withAlphaComponent(codeBlockWashAlpha))?.composited(over: page) ?? page
                // In the app's conversation, code sits on a card: the
                // window's background under a label-color fill.
                let window = SRGB(NSColor.windowBackgroundColor) ?? page
                let card = SRGB(NSColor.labelColor.withAlphaComponent(cardFillAlphaLimit))?.composited(over: window) ?? window
                let foreground = SRGB(base)?.composited(over: page) ?? page.extreme
                resolved = adjusted(foreground, against: [page, wash, card]).color
            }
            return resolved
        }
    }

    /// The opacity of ChatMarkdownKit's code-block background
    /// (MarkdownRenderStyle.codeBackground, labelColor at 8%).
    public static let codeBlockWashAlpha: CGFloat = 0.08

    /// The strongest card fill the app draws code on: Theme's cardFill
    /// under Increase Contrast (14%; 8% light and 9% dark otherwise).
    /// Clearing the strongest clears them all.
    static let cardFillAlphaLimit: CGFloat = 0.14

    /// The least blend that clears `targetContrast` against every background.
    /// They all lie on the same side of the foreground (all light or all
    /// dark), so blending toward the page's opposite extreme helps against each.
    static func adjusted(_ foreground: SRGB, against backgrounds: [SRGB]) -> SRGB {
        guard let page = backgrounds.first else { return foreground }
        func clears(_ color: SRGB) -> Bool {
            backgrounds.allSatisfy { color.contrastRatio(with: $0) >= targetContrast }
        }
        if clears(foreground) { return foreground }
        let extreme = page.extreme
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<blendSearchSteps {
            let mid = (low + high) / 2
            if clears(foreground.blended(toward: extreme, fraction: mid)) {
                high = mid
            } else {
                low = mid
            }
        }
        return foreground.blended(toward: extreme, fraction: high)
    }

    /// The least blend of `foreground` toward the background's opposite
    /// extreme that meets `targetContrast`; `foreground` itself if it already does.
    static func adjusted(_ foreground: SRGB, against background: SRGB) -> SRGB {
        if foreground.contrastRatio(with: background) >= targetContrast {
            return foreground
        }
        let extreme = background.extreme
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<blendSearchSteps {
            let mid = (low + high) / 2
            if foreground.blended(toward: extreme, fraction: mid).contrastRatio(with: background) >= targetContrast {
                high = mid
            } else {
                low = mid
            }
        }
        return foreground.blended(toward: extreme, fraction: high)
    }
}

/// The kinds of token the highlighter colors, with the system color each starts from.
enum CodeToken: CaseIterable, Sendable {
    case keyword, string, type, function, number, comment, property, preprocessor, escape

    var baseColor: NSColor {
        switch self {
        case .keyword: .systemPink
        case .string: .systemRed
        case .type: .systemPurple
        case .function: .systemBlue
        case .number: .systemOrange
        case .comment: .secondaryLabelColor
        case .property: .systemTeal
        case .preprocessor: .systemBrown
        case .escape: .systemIndigo
        }
    }
}

/// An sRGB color with alpha, and the WCAG 2.x luminance math on it.
struct SRGB: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    static let white = SRGB(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = SRGB(red: 0, green: 0, blue: 0, alpha: 1)

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Resolves `color` in the current drawing appearance. Nil if it has no
    /// sRGB form (a pattern color, say).
    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }

    var color: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// WCAG 2.x relative luminance.
    var relativeLuminance: CGFloat {
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrastRatio(with other: SRGB) -> CGFloat {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This color drawn over an opaque `background`, as an opaque color.
    func composited(over background: SRGB) -> SRGB {
        SRGB(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha),
            alpha: 1
        )
    }

    func blended(toward target: SRGB, fraction: CGFloat) -> SRGB {
        SRGB(
            red: red + (target.red - red) * fraction,
            green: green + (target.green - green) * fraction,
            blue: blue + (target.blue - blue) * fraction,
            alpha: alpha
        )
    }

    /// Black on a light background, white on a dark one: whichever end gives more contrast.
    var extreme: SRGB {
        contrastRatio(with: .black) >= contrastRatio(with: .white) ? .black : .white
    }
}
