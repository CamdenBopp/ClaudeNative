import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
import ClaudeNativeCore

/// The message field's plain style has no focus ring, so its card's border
/// shows focus instead: drawn in the accent color while the field has
/// keyboard focus, so a low-vision keyboard user can see where typing goes.
@MainActor
struct ComposerFocusTests {
    /// How many of the border's pixels are clearly colored, not gray.
    static func coloredPixels(_ view: some View) throws -> Int {
        let host = NSHostingView(rootView: view.frame(width: 200, height: 80).padding(8).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var count = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.saturationComponent > 0.4 { count += 1 }
        } }
        return count
    }

    @Test func theBorderShowsFocus() throws {
        #expect(try Self.coloredPixels(ComposerBorder(isFocused: false)) == 0)
        #expect(try Self.coloredPixels(ComposerBorder(isFocused: true)) > 400)
    }

    /// Like a focus ring, it isn't drawn while the window is in the
    /// background.
    @Test func theBorderShowsNoFocusInAnInactiveWindow() throws {
        #expect(try Self.coloredPixels(ComposerBorder(isFocused: true).environment(\.controlActiveState, .inactive)) == 0)
    }

    struct FieldHost: View {
        @State var draft = ""
        @State var attachments: [ImageAttachment] = []
        @FocusState var focused: Bool
        var placeholder = ComposerPlaceholder.inConversation
        var body: some View {
            Composer(
                draft: $draft, attachments: $attachments, focus: $focused, isReady: true, isWorking: false,
                usageLimits: nil, contextUsage: nil, send: {}, stop: {}, attachImages: {},
                placeholder: placeholder
            )
            .padding()
        }
    }

    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + views(type, in: $0) }
    }

    /// Check the exposed field's label, rather than the backing AppKit
    /// field's placeholder: SwiftUI supplies the accessibility element.
    @Test func theFieldFocusLandsOnIsNamed() throws {
        let (window, host) = AccessibilityHost.window(hosting: FieldHost(), size: NSSize(width: 700, height: 300))
        AccessibilityHost.settle(host)
        defer { window.close() }
        let field = try #require(AccessibilityHost.descendants(of: host).first { AccessibilityHost.role($0) == .textField })
        #expect(AccessibilityHost.label(field) == ComposerPlaceholder.inConversation)
    }

    /// A new conversation's field says what the Claude app's does, and is
    /// named by it.
    @Test func aNewConversationsFieldAsksForATask() throws {
        let (window, host) = AccessibilityHost.window(hosting: FieldHost(placeholder: ComposerPlaceholder.newConversation), size: NSSize(width: 700, height: 300))
        AccessibilityHost.settle(host)
        defer { window.close() }
        let field = try #require(AccessibilityHost.descendants(of: host).first { AccessibilityHost.role($0) == .textField })
        #expect(AccessibilityHost.label(field) == "Describe a task or ask a question")
    }
}

/// A new conversation's heading, in the Claude app's words.
struct EmptyConversationWordingTests {
    @Test func greetsByFirstName() {
        #expect(EmptyConversationWording.heading(fullName: "Sam Rivera") == "What's up next, Sam?")
        #expect(EmptyConversationWording.heading(fullName: "") == "What's up next?")
    }
}
