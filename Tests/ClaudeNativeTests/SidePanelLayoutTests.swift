import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative

/// The side panel's bar stays at its top whatever the panel shows.
@MainActor
struct SidePanelLayoutTests {
    /// With no file open the panel showed "No File Open" with its bar
    /// halfway down, centered with the message, not at the top.
    @Test func theBarIsAtTheTopWithNoFileOpen() throws {
        let panel = SidePanel()
        let size = NSSize(width: 500, height: 600)
        let (window, _) = AccessibilityHost.window(hosting: SidePanelView(panel: panel, base: nil).frame(width: size.width, height: size.height), size: size)
        let content = try #require(window.contentView)
        AccessibilityHost.settle(content)
        let close = try #require(AccessibilityHost.descendants(of: content).first { AccessibilityHost.label($0) == "Close Panel" })
        let frame = try #require((close as? NSAccessibilityElementProtocol)?.accessibilityFrame())
        // Screen coordinates: the button's top against the content's top.
        let contentTop = window.convertToScreen(content.convert(content.bounds, to: nil)).maxY
        #expect(contentTop - frame.maxY < Self.barTopSlack, "the bar's Close button is \(contentTop - frame.maxY) points down")
    }

    /// The changes list that couldn't load ("Choose a folder first.") kept
    /// its bar at the top too.
    @Test func theBarIsAtTheTopWhenChangesFailToLoad() async throws {
        let panel = SidePanel()
        panel.open(.projectChanges, focus: false)
        let size = NSSize(width: 500, height: 600)
        let (window, _) = AccessibilityHost.window(hosting: SidePanelView(panel: panel, base: nil).frame(width: size.width, height: size.height), size: size)
        let content = try #require(window.contentView)
        AccessibilityHost.settle(content)
        try await Task.sleep(for: .milliseconds(200))
        AccessibilityHost.settle(content)
        #expect(AccessibilityHost.descendants(of: content).contains { (AccessibilityHost.label($0) ?? AccessibilityHost.value($0) ?? "").contains("Choose a folder first") })
        let close = try #require(AccessibilityHost.descendants(of: content).first { AccessibilityHost.label($0) == "Close Changes" })
        let frame = try #require((close as? NSAccessibilityElementProtocol)?.accessibilityFrame())
        let contentTop = window.convertToScreen(content.convert(content.bounds, to: nil)).maxY
        #expect(contentTop - frame.maxY < Self.barTopSlack, "the bar's Close button is \(contentTop - frame.maxY) points down")
    }

    /// The close button says what it closes: over a side chat it read
    /// "Close Editor", as if the panel held the code editor.
    @Test func theCloseButtonNamesWhatItCloses() throws {
        let panel = SidePanel()
        panel.open(.sideChat, focus: false)
        let size = NSSize(width: 500, height: 600)
        let (window, _) = AccessibilityHost.window(hosting: SidePanelView(panel: panel, base: nil).frame(width: size.width, height: size.height), size: size)
        let content = try #require(window.contentView)
        AccessibilityHost.settle(content)
        let labels = AccessibilityHost.descendants(of: content).compactMap(AccessibilityHost.label)
        #expect(labels.contains("Close Side Chat"))
        #expect(!labels.contains("Close Editor"))
    }

    /// Expand only applies to a shown panel, and closing the panel puts
    /// it back beside the session for next time.
    @Test func expandingNeedsAShownPanelAndClosingUndoesIt() {
        let panel = SidePanel()
        panel.toggleExpanded()
        #expect(!panel.isExpanded)
        panel.open(.files, focus: false)
        panel.toggleExpanded()
        #expect(panel.isExpanded)
        panel.close()
        #expect(!panel.isExpanded)
        panel.open(.files, focus: false)
        #expect(!panel.isExpanded)
    }

    /// The bar's padding and the button's own inset, with room to spare;
    /// the centered bar was about 280 points down.
    static let barTopSlack: CGFloat = 24
}
