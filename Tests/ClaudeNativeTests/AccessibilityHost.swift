import AppKit
import Foundation
import SwiftUI
@testable import ClaudeNativeCore

/// Real CLI captures from Tests/Fixtures, replayed through the parser and
/// transcript as the app consumes them. The same steps as
/// ClaudeNativeCoreTests' FixtureReplayTests, which this target can't import.
enum Fixtures {
    private struct Line: Decodable {
        let dir: String
        let msg: JSONValue
    }

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures")

    static func events(_ name: String) throws -> [StreamEvent] {
        let text = try String(contentsOf: directory.appending(path: "\(name).jsonl"), encoding: .utf8)
        return try text.split(separator: "\n")
            .map { try JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
            .filter { $0.dir == "stdout" }
            .compactMap { try StreamEvent.read(JSONValue.parse($0.msg.line())) }
    }

    static func replay(_ name: String, userText: String = "prompt") throws -> Transcript {
        var transcript = Transcript()
        transcript.appendUser(userText)
        for event in try events(name) { transcript.apply(event) }
        return transcript
    }

    static func permissionRequests(_ name: String) throws -> [PermissionRequest] {
        try events(name).compactMap {
            if case .permissionRequest(let request) = $0 { return request }
            return nil
        }
    }
}

/// Hosting real views in a window, with AppKit's accessibility tree built
/// as it is when VoiceOver is running.
@MainActor
enum AccessibilityHost {
    /// SwiftUI's NSHostingView only builds its accessibility nodes once an
    /// assistive app has asked for them. Without this the hosting view has
    /// no accessibility children in a test process (no buttons, no
    /// representable views). Setting AXEnhancedUserInterface on the
    /// application is what an assistive client does, and it turns the tree
    /// on. NSApplication has no public setter for it, hence the attribute.
    static func enable() {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    static func window<Content: View>(hosting view: Content, size: NSSize) -> (NSWindow, NSHostingView<Content>) {
        enable()
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host)
        return (window, host)
    }

    /// Lets SwiftUI apply a new root view and lay out, as a pass of the
    /// app's run loop would.
    static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
    }

    // The accessors below message elements by selector, as the accessibility
    // server does. SwiftUI's nodes (AccessibilityNode) answer these
    // selectors but don't cast to NSAccessibilityProtocol in Swift, so an
    // `as? NSAccessibilityProtocol` walk silently skips every SwiftUI
    // button and label.

    /// Every element under `root` in accessibility order, depth first.
    static func descendants(of root: AnyObject) -> [AnyObject] {
        var found: [AnyObject] = []
        func walk(_ element: AnyObject) {
            for child in children(element) {
                found.append(child)
                walk(child)
            }
        }
        walk(root)
        return found
    }

    static func children(_ element: AnyObject) -> [AnyObject] {
        (element.accessibilityChildren?() ?? nil)?.map { $0 as AnyObject } ?? []
    }

    static func role(_ element: AnyObject) -> NSAccessibility.Role? {
        element.accessibilityRole?() ?? nil
    }

    static func label(_ element: AnyObject) -> String? {
        element.accessibilityLabel?() ?? nil
    }

    static func value(_ element: AnyObject) -> String? {
        // `accessibilityValue` is declared with several return types across
        // AppKit, so it's sent by selector name.
        let selector = #selector(NSAccessibilityProtocol.accessibilityValue)
        guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    static func customActions(_ element: AnyObject) -> [NSAccessibilityCustomAction] {
        element.accessibilityCustomActions?() ?? nil ?? []
    }

    static func customRotors(_ element: AnyObject) -> [NSAccessibilityCustomRotor] {
        element.accessibilityCustomRotors?() ?? []
    }

    /// A key press, as the window gets it before any view sees it as typing.
    static func pressKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else {
            // Returning false here would let "Return answers nothing" pass
            // without a key ever being pressed.
            preconditionFailure("Couldn't make a key event for \(characters.debugDescription)")
        }
        return window.performKeyEquivalent(with: event)
    }
}
