import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
import ClaudeNativeCore

/// The permission prompt presented as the app presents it, a SwiftUI sheet
/// on a window, with every part of it inside the sheet.
///
/// A suggestion title held to one line wider than the sheet pushed the whole
/// layout past both edges: the sheet showed the middle, with the question,
/// the command and Deny and Allow Once cut in half.
@MainActor
struct PermissionSheetLayoutTests {
    /// The real request from real_always_allow.jsonl, offering rules for two
    /// longer commands, as the CLI offers for any compound command.
    static func longRuleRequest() throws -> PermissionRequest {
        let real = try #require(try Fixtures.permissionRequests("real_always_allow").first)
        let command = "xcodebuild -scheme ClaudeNative -destination platform=macOS build && swift test --filter PermissionSheetKeyboardTests"
        let suggestion: JSONValue = .object([
            "type": .string("addRules"), "behavior": .string("allow"), "destination": .string("localSettings"),
            "rules": .array([
                .object(["toolName": .string("Bash"), "ruleContent": .string("xcodebuild -scheme ClaudeNative -destination platform=macOS build")]),
                .object(["toolName": .string("Bash"), "ruleContent": .string("swift test --filter PermissionSheetKeyboardTests")]),
            ]),
        ])
        return PermissionRequest(
            requestID: real.requestID, toolName: real.toolName,
            input: .object(["command": .string(command)]),
            toolUseID: real.toolUseID, rawSuggestions: .array([suggestion])
        )
    }

    /// Presents the sheet and returns its window once it has laid out.
    static func present(_ request: PermissionRequest) throws -> (parent: NSWindow, sheet: NSWindow) {
        AccessibilityHost.enable()
        let sheet = PermissionSheet(request: request, diff: nil, base: nil) { _, _ in }
        let root = Color.clear
            .frame(width: Self.parentSize.width, height: Self.parentSize.height)
            .sheet(isPresented: .constant(true)) { sheet }
        let parent = NSWindow(contentRect: NSRect(origin: .zero, size: Self.parentSize), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentView = NSHostingView(rootView: root)
        parent.orderFront(nil)
        // A sheet animates in over several passes of the run loop.
        let deadline = Date().addingTimeInterval(Self.presentTimeout)
        while parent.attachedSheet == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let window = try #require(parent.attachedSheet)
        AccessibilityHost.settle(try #require(window.contentView))
        return (parent, window)
    }

    static let parentSize = NSSize(width: 900, height: 700)
    static let presentTimeout: TimeInterval = 2

    static func frame(_ element: AnyObject) -> NSRect? {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard element.responds(to: selector) else { return nil }
        return (element as? NSObject)?.value(forKey: "accessibilityFrame") as? NSRect
    }

    @Test func everyButtonAndTheQuestionAreInsideTheSheet() throws {
        let request = try Self.longRuleRequest()
        let (parent, sheet) = try Self.present(request)
        defer { parent.endSheet(sheet); parent.close() }
        let elements = AccessibilityHost.descendants(of: sheet)
        let buttons = elements.filter { AccessibilityHost.role($0) == .button }
        let suggestion = try #require(request.suggestions.first)
        // VoiceOver hears the whole rule on the button, however it's drawn.
        #expect(buttons.compactMap(AccessibilityHost.label) == ["Deny", suggestion.title, "Allow Once"])
        let question = try #require(elements.first { AccessibilityHost.label($0)?.hasPrefix("Allow Claude to run") == true })
        let bounds = sheet.frame.insetBy(dx: -0.5, dy: -0.5)
        for element in buttons + [question] {
            let frame = try #require(Self.frame(element))
            #expect(bounds.contains(frame), "\(AccessibilityHost.label(element) ?? "?") at \(frame) is outside the sheet at \(sheet.frame)")
        }
    }
}
