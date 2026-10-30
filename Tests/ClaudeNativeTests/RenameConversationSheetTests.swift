import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative

/// The rename sheet's field says what it's for: VoiceOver arriving in it
/// read only the old title and "edit text".
@MainActor
struct RenameConversationSheetTests {
    @Test func theTitleFieldIsNamed() throws {
        let sheet = RenameConversationSheet(title: "Rivers") { _ in }
        let (window, host) = AccessibilityHost.window(hosting: sheet, size: NSSize(width: 420, height: 200))
        AccessibilityHost.settle(host)
        defer { window.close() }
        let field = try #require(AccessibilityHost.descendants(of: host).first { AccessibilityHost.role($0) == .textField })
        #expect(AccessibilityHost.label(field) == "New title")
        #expect(AccessibilityHost.value(field) == "Rivers")
    }
}
