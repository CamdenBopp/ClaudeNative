import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative

/// Icon-only buttons are at least `Theme.iconButtonSize` square, not the
/// size of their glyph (Close Editor measured 10 by 10 points), and keep
/// their names.
@MainActor
struct IconTargetTests {
    static func frames(_ labels: [String], hosting view: some View) throws -> [String: NSRect] {
        let (window, host) = AccessibilityHost.window(hosting: view, size: NSSize(width: 700, height: 400))
        defer { window.close() }
        AccessibilityHost.settle(host)
        var found: [String: NSRect] = [:]
        for label in labels {
            let element = try #require(AccessibilityHost.descendants(of: host).first { AccessibilityHost.label($0) == label }, "no \(label)")
            found[label] = try #require((element as? NSAccessibilityElementProtocol)?.accessibilityFrame())
        }
        return found
    }

    @Test func theSidePanelBarsButtonsAreEasyToHit() throws {
        let frames = try Self.frames(["Back", "Close Panel"], hosting: SidePanelView(panel: SidePanel(), base: nil).frame(width: 500, height: 400))
        for (label, frame) in frames {
            #expect(frame.width >= Theme.iconButtonSize && frame.height >= Theme.iconButtonSize, "\(label) is \(frame.size)")
        }
    }

    @Test func theComposersButtonsAreEasyToHit() throws {
        let frames = try Self.frames(["Add", "Send"], hosting: ComposerFocusTests.FieldHost())
        for (label, frame) in frames {
            #expect(frame.width >= Theme.iconButtonSize && frame.height >= Theme.iconButtonSize, "\(label) is \(frame.size)")
        }
    }

    /// The mode and model choices are as tall as the icon buttons beside
    /// them: SwiftUI's borderless Menu measured 16 points.
    @Test func theComposersChoicesAreEasyToHit() throws {
        struct Host: View {
            @State var mode = "default"
            @State var model = "default"
            @State var effort = "auto"
            var body: some View {
                HStack {
                    ModeMenu(selection: $mode)
                    ModelMenu(model: $model, effort: $effort, models: [], effortLevels: [])
                }
            }
        }
        let frames = try Self.frames(["Mode: Manual", "Model: Default"], hosting: Host())
        for (label, frame) in frames {
            #expect(frame.height >= Theme.iconButtonSize, "\(label) is \(frame.size)")
        }
    }
}
