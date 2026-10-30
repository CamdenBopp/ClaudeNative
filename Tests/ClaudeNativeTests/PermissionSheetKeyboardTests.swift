import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
import ClaudeNativeCore

/// The permission prompt's keys, pressed at the real hosted sheet. Return
/// must never answer it: a VoiceOver user sending a message as the prompt
/// appears would approve a command they never heard.
///
/// SwiftUI's buttons are accessibility nodes, not NSButtons, and expose no
/// key equivalent or default/cancel button to the tree, so the keys are
/// asserted by what pressing them does through the window.
@MainActor
struct PermissionSheetKeyboardTests {
    final class Answers {
        var given: [(allow: Bool, suggestion: PermissionSuggestion?)] = []
    }

    /// Real requests: a plain Write, and a Bash request whose suggestions
    /// add "always allow" buttons.
    nonisolated static let fixtures = ["real_permission_allow", "real_always_allow"]

    static func host(_ fixture: String) throws -> (NSWindow, Answers, PermissionRequest) {
        let request = try #require(try Fixtures.permissionRequests(fixture).first)
        let answers = Answers()
        let sheet = PermissionSheet(request: request, diff: nil, base: nil, answerDelay: .zero) { allow, suggestion in
            answers.given.append((allow, suggestion))
        }
        let (window, _) = AccessibilityHost.window(hosting: sheet, size: NSSize(width: 720, height: 300))
        return (window, answers, request)
    }

    static let returnKey: (String, UInt16) = ("\r", 36)
    static let escapeKey: (String, UInt16) = ("\u{1b}", 53)

    @Test(arguments: fixtures)
    func buttonsAreInTheTree(fixture: String) throws {
        let (window, _, request) = try Self.host(fixture)
        let host = try #require(window.contentView)
        let buttons = AccessibilityHost.descendants(of: host)
            .filter { AccessibilityHost.role($0) == .button }
            .compactMap(AccessibilityHost.label)
        #expect(buttons == ["Deny"] + request.suggestions.map(\.title) + ["Allow Once"])
    }

    /// VoiceOver reads the command the moment it reaches it; an unnamed
    /// scroll area around it only said "scroll area" and hid the command
    /// one level down.
    @Test func theCommandIsNotHiddenInAnUnnamedScrollArea() throws {
        let (window, _, request) = try Self.host("real_always_allow")
        let host = try #require(window.contentView)
        let detail = try #require(PermissionWording.detail(toolName: request.toolName, input: request.input))
        let all = AccessibilityHost.descendants(of: host)
        let unnamed = all.filter { AccessibilityHost.role($0) == .scrollArea && (AccessibilityHost.label($0) ?? "").isEmpty }
        #expect(unnamed.isEmpty, "unnamed scroll areas: \(unnamed.count)")
        #expect(all.contains { (AccessibilityHost.label($0) ?? "").contains(detail) || (AccessibilityHost.value($0) ?? "").contains(detail) })
    }

    @Test(arguments: fixtures)
    func returnAnswersNothing(fixture: String) throws {
        let (window, answers, _) = try Self.host(fixture)
        let handled = AccessibilityHost.pressKey(Self.returnKey.0, keyCode: Self.returnKey.1, in: window)
        // Give anything Return might have started a pass of the run loop.
        AccessibilityHost.settle(try #require(window.contentView))
        #expect(!handled)
        #expect(answers.given.isEmpty)
    }

    @Test(arguments: fixtures)
    func escapeDenies(fixture: String) throws {
        let (window, answers, _) = try Self.host(fixture)
        #expect(AccessibilityHost.pressKey(Self.escapeKey.0, keyCode: Self.escapeKey.1, in: window))
        #expect(answers.given.map(\.allow) == [false])
        #expect(answers.given.first?.suggestion == nil)
    }

    /// Escape rejects a plan even with the keyboard in the plan's text,
    /// where AppKit's text view took it as "complete the word" and the
    /// sheet stayed up.
    @Test func escapeInThePlanTextRejects() throws {
        let request = PermissionRequest(requestID: "p1", toolName: "ExitPlanMode", input: .object(["plan": .string("# Plan\n\n1. Step")]))
        let answers = Answers()
        let sheet = PermissionSheet(request: request, diff: nil, base: nil, answerDelay: .zero) { allow, suggestion in
            answers.given.append((allow, suggestion))
        }
        let (window, _) = AccessibilityHost.window(hosting: sheet, size: NSSize(width: 720, height: 520))
        let host = try #require(window.contentView)
        let text = try #require(Self.textView(in: host))
        #expect(window.makeFirstResponder(text))
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: Self.escapeKey.0, charactersIgnoringModifiers: Self.escapeKey.0, isARepeat: false, keyCode: Self.escapeKey.1
        ))
        text.keyDown(with: escape)
        AccessibilityHost.settle(host)
        #expect(answers.given.map(\.allow) == [false])
    }

    static func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    @Test(arguments: fixtures)
    func commandReturnAllowsOnce(fixture: String) throws {
        let (window, answers, _) = try Self.host(fixture)
        #expect(AccessibilityHost.pressKey(Self.returnKey.0, keyCode: Self.returnKey.1, modifiers: .command, in: window))
        #expect(answers.given.map(\.allow) == [true])
        #expect(answers.given.first?.suggestion == nil)
    }
}

/// A press too soon after a request appears doesn't answer it: one meant
/// for the request before (a double-click, Escape twice, a held key)
/// answered this one before it was read out.
@MainActor
struct PermissionSheetSettleTests {
    @Test func aPressAsTheRequestAppearsIsIgnored() async throws {
        let request = try #require(try Fixtures.permissionRequests("real_always_allow").first)
        let answers = PermissionSheetKeyboardTests.Answers()
        let sheet = PermissionSheet(request: request, diff: nil, base: nil) { allow, suggestion in
            answers.given.append((allow, suggestion))
        }
        let (window, _) = AccessibilityHost.window(hosting: sheet, size: NSSize(width: 720, height: 300))
        defer { window.close() }
        let escape = PermissionSheetKeyboardTests.escapeKey
        _ = AccessibilityHost.pressKey(escape.0, keyCode: escape.1, in: window)
        #expect(answers.given.isEmpty)
        try await Task.sleep(for: PermissionSheet.answerDelay + .milliseconds(100))
        _ = AccessibilityHost.pressKey(escape.0, keyCode: escape.1, in: window)
        #expect(answers.given.map(\.allow) == [false])
    }
}

/// The prompt's heading for an MCP tool, read from the hosted sheet's
/// accessibility tree. The tool name is verbatim from a real system/init
/// line (Tests/Fixtures/real_init_mcp_tools.jsonl).
@MainActor
struct PermissionSheetTitleTests {
    @Test func mcpToolHeadingIsSpokenInWords() throws {
        let request = PermissionRequest(
            requestID: "r1",
            toolName: "mcp__chrome-devtools__navigate",
            input: .object(["url": .string("https://example.com")])
        )
        let sheet = PermissionSheet(request: request, diff: nil, base: nil) { _, _ in }
        let (window, _) = AccessibilityHost.window(hosting: sheet, size: NSSize(width: 720, height: 300))
        let host = try #require(window.contentView)
        let texts = AccessibilityHost.descendants(of: host)
            .flatMap { [AccessibilityHost.label($0), AccessibilityHost.value($0)] }
            .compactMap { $0 }
        #expect(texts.contains("Allow Claude to use navigate (chrome devtools)?"))
        #expect(texts.contains("Claude wants to use navigate (chrome devtools)."))
        #expect(texts.contains("https://example.com"))
        #expect(!texts.contains { $0.contains("mcp__") })
    }

    /// A command's question says what Claude will run, as the Claude app
    /// asks it, so the "wants to run a command" line under it would repeat.
    @Test func commandQuestionReplacesTheExplanation() throws {
        let request = PermissionRequest(requestID: "r2", toolName: "Bash", input: .object(["command": .string("touch a.txt")]))
        let sheet = PermissionSheet(request: request, diff: nil, base: nil) { _, _ in }
        let (window, _) = AccessibilityHost.window(hosting: sheet, size: NSSize(width: 720, height: 300))
        let host = try #require(window.contentView)
        let texts = AccessibilityHost.descendants(of: host)
            .flatMap { [AccessibilityHost.label($0), AccessibilityHost.value($0)] }
            .compactMap { $0 }
        #expect(texts.contains("Allow Claude to run touch a.txt?"))
        #expect(!texts.contains("Claude wants to run a command."))
    }

    /// A plan reads as formatted text, as a reply does: VoiceOver gets the
    /// words of a heading, not its "##".
    @Test func planReadsWithoutMarkdownSymbols() throws {
        let plan = "# Plan: add hello.txt\n\n## Steps\n1. Write `hello.txt` with `hello`.\n2. Check it."
        let request = PermissionRequest(requestID: "p1", toolName: "ExitPlanMode", input: .object(["plan": .string(plan)]))
        let sheet = PermissionSheet(request: request, diff: nil, base: nil) { _, _ in }
        let (window, _) = AccessibilityHost.window(hosting: sheet, size: NSSize(width: 720, height: 520))
        let host = try #require(window.contentView)
        let texts = AccessibilityHost.descendants(of: host)
            .flatMap { [AccessibilityHost.label($0), AccessibilityHost.value($0)] }
            .compactMap { $0 }
        #expect(texts.contains("Claude proposed a plan"))
        let shown = try #require(texts.first { $0.contains("Plan: add hello.txt") })
        #expect(shown.contains("Steps"))
        #expect(!shown.contains("#"))
        #expect(!shown.contains("`"))
    }
}
