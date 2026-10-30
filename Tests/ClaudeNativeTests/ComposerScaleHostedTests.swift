import AppKit
import ClaudeNativeCore
import SwiftUI
import Testing
@testable import ClaudeNative

/// Bigger Text sizes the message field's buttons along with what you type,
/// so at the largest size Add and Send aren't left as small icons beside
/// large text.
@MainActor
@Suite(.serialized)
struct ComposerScaleHostedTests {
    struct Host: View {
        @State var draft = "hello"
        @State var attachments: [ImageAttachment] = []
        @FocusState var focused: Bool
        var body: some View {
            Composer(
                draft: $draft, attachments: $attachments, focus: $focused, isReady: true, isWorking: false,
                usageLimits: nil, contextUsage: nil, send: {}, stop: {}, attachImages: {}
            )
            .padding()
        }
    }

    func buttonHeight(_ label: String, scale: Double) throws -> CGFloat {
        UserDefaults.standard.set(scale, forKey: TextScale.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: TextScale.defaultsKey) }
        let (window, host) = AccessibilityHost.window(hosting: Host(), size: NSSize(width: 900, height: 400))
        AccessibilityHost.settle(host)
        defer { window.close() }
        let button = try #require(AccessibilityHost.descendants(of: host).first {
            AccessibilityHost.label($0) == label && AccessibilityHost.role($0) == .button
        })
        return (button.accessibilityFrame?() ?? .zero).height
    }

    @Test func attachAndSendGrowWithTheText() throws {
        for label in ["Add", "Send"] {
            let standard = try buttonHeight(label, scale: 1)
            let largest = try buttonHeight(label, scale: 3)
            // At 1x each is the 24-point minimum target, so growth is
            // measured against that: 38 to 42 points at 3x, where a fixed
            // icon stayed 24.
            #expect(largest > standard * 1.5, "\(label): \(standard) at 1x, \(largest) at 3x")
        }
    }
}
