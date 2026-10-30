import ClaudeNativeCore
import SwiftUI

/// How full the context window is, as a ring in the composer's bar, as the
/// Claude app shows it. The usage sentence under the card says the same in
/// words, so the ring is hidden from VoiceOver; the pointer shows that
/// sentence as its help.
struct ContextRing: View {
    let usage: ContextUsage
    /// The sentence under the card, for the pointer.
    let help: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(nsColor: Theme.contextRingTrack), lineWidth: ContextRingLayout.lineWidth)
            Circle()
                .trim(from: 0, to: min(max(usage.fraction, 0), 1))
                // The label color: the filled part must read against the
                // track at low vision, as the text beside it does.
                .stroke(Color(nsColor: .labelColor), style: StrokeStyle(lineWidth: ContextRingLayout.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: ContextRingLayout.diameter, height: ContextRingLayout.diameter)
        .frame(minWidth: Theme.iconButtonSize, minHeight: Theme.iconButtonSize)
        .help(help ?? "Context window")
        .accessibilityHidden(true)
    }
}

enum ContextRingLayout {
    /// About the height of the bar's text, so it sits like a glyph.
    static let diameter: CGFloat = 14
    static let lineWidth: CGFloat = 2.5
}
