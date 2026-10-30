import AppKit
import SwiftUI

/// Visible placeholder text without a reading stop of its own. A hidden
/// Canvas still created an AXUnknown element in the running app; VoiceOver
/// entered it as "content is empty" before reaching the message field.
struct ComposerPlaceholderView: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat

    func makeNSView(context: Context) -> PlaceholderDrawingView { PlaceholderDrawingView() }

    func updateNSView(_ view: PlaceholderDrawingView, context: Context) {
        view.text = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: Theme.quietLabel,
        ])
        view.needsDisplay = true
    }

    final class PlaceholderDrawingView: NSView {
        var text = NSAttributedString()

        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { text.draw(in: bounds) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityChildren() -> [Any]? { [] }
    }
}
