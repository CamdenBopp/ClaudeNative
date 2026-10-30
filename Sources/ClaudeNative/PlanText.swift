import AppKit
import SwiftUI

/// A plan drawn as a reply is: headings, lists and code formatted rather
/// than shown as Markdown, so VoiceOver reads the words, not "number sign"
/// and backticks. Selectable, for copying a step.
struct PlanText: NSViewRepresentable {
    let markdown: String
    let bodySize: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let text = PlanTextView()
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scrollView.documentView = text
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: Theme.Spacing.medium, height: Theme.Spacing.medium)
        text.setAccessibilityLabel("Plan")
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let text = scrollView.documentView as? NSTextView,
              context.coordinator.shown != markdown || context.coordinator.size != bodySize else { return }
        context.coordinator.shown = markdown
        context.coordinator.size = bodySize
        let renderer = StreamingMarkdown()
        renderer.bodySize = bodySize
        let partial = renderer.render(markdown)
        text.textStorage?.setAttributedString(renderer.finish() ?? partial)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Hands Escape to the sheet: a text view takes it as "complete the
    /// word", which left the sheet up with Reject never pressed. SwiftUI's
    /// cancel button answers the window's key equivalents, not
    /// cancelOperation up the responder chain.
    final class PlanTextView: NSTextView {
        static let escapeKeyCode: UInt16 = 53

        override func keyDown(with event: NSEvent) {
            if event.keyCode == Self.escapeKeyCode, window?.performKeyEquivalent(with: event) == true { return }
            super.keyDown(with: event)
        }
    }

    final class Coordinator {
        var shown: String?
        var size: CGFloat?
    }
}
