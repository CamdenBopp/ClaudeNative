import AppKit
import ClaudeNativeCore
import SwiftUI
import Testing
@testable import ClaudeNative

/// The slash command list in the real Composer, driven by key presses sent
/// to the focused message field, as typing does.
@MainActor
@Suite(.serialized)
struct SlashCommandPickerTests {
    final class Box {
        var draft = ""
        var sent: [String] = []
        var setReady: (Bool) -> Void = { _ in }
    }

    struct Host: View {
        let box: Box
        let commands: [SlashCommand]
        var initialAttachments: [ImageAttachment] = []
        var isReady = true
        @State var ready: Bool?
        @State var draft = ""
        @State var attachments: [ImageAttachment] = []
        @FocusState var focused: Bool

        var body: some View {
            Composer(
                draft: $draft, attachments: $attachments, focus: $focused, isReady: ready ?? isReady, isWorking: false,
                usageLimits: nil, contextUsage: nil,
                send: { box.sent.append(draft); draft = "" }, stop: {}, attachImages: {},
                commands: commands
            )
            .onAppear {
                attachments = initialAttachments
                focused = true
                box.setReady = { ready = $0 }
            }
            .onChange(of: draft) { box.draft = draft }
        }
    }

    static let commands = [
        SlashCommand(name: "compact", description: "Free up context by summarizing the conversation so far",
                     argumentHint: "<optional custom summarization instructions>"),
        SlashCommand(name: "context", description: "Visualize current context usage"),
        SlashCommand(name: "cost", description: "Show the total cost of this session"),
        SlashCommand(name: "model", description: "Set the AI model for Claude Code", argumentHint: "<model>"),
    ]

    static func host() throws -> (NSWindow, Box) {
        let box = Box()
        let (window, view) = AccessibilityHost.window(hosting: Host(box: box, commands: commands), size: NSSize(width: 700, height: 400))
        AccessibilityHost.settle(view)
        return (window, box)
    }

    /// Sends a key to whatever has keyboard focus.
    static func press(_ characters: String, keyCode: UInt16, in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
        window.sendEvent(event)
        AccessibilityHost.settle(try #require(window.contentView))
    }

    static func type(_ text: String, in window: NSWindow) throws {
        let editor = try #require(window.firstResponder as? NSTextView, "the message field has focus")
        editor.insertText(text, replacementRange: editor.selectedRange())
        AccessibilityHost.settle(try #require(window.contentView))
    }

    /// The list's rows as VoiceOver reads them, and which is selected.
    static func rows(_ window: NSWindow) throws -> [(label: String, selected: Bool)] {
        let root = try #require(window.contentView)
        return AccessibilityHost.descendants(of: root)
            .filter { AccessibilityHost.role($0) == .button }
            .compactMap { element in
                guard let label = AccessibilityHost.label(element), label.hasPrefix("/") else { return nil }
                return (label, (element.isAccessibilitySelected?() ?? false))
            }
    }

    static let down = ("\u{F701}", UInt16(125)), up = ("\u{F700}", UInt16(126))
    static let tab = ("\t", UInt16(48)), returnKey = ("\r", UInt16(36)), escape = ("\u{1b}", UInt16(53))

    @Test func typingASlashListsTheMatchingCommands() throws {
        let (window, _) = try Self.host()
        #expect(try Self.rows(window).isEmpty)
        try Self.type("/co", in: window)
        let rows = try Self.rows(window)
        #expect(rows.map(\.label) == [
            "/compact, Free up context by summarizing the conversation so far",
            "/context, Visualize current context usage",
            "/cost, Show the total cost of this session",
        ])
        #expect(rows.map(\.selected) == [true, false, false])
        // A space ends the command; the list goes.
        try Self.type(" ", in: window)
        #expect(try Self.rows(window).isEmpty)
    }

    @Test func arrowsMoveTheHighlightAndWrap() throws {
        let (window, _) = try Self.host()
        try Self.type("/co", in: window)
        try Self.press(Self.down.0, keyCode: Self.down.1, in: window)
        #expect(try Self.rows(window).map(\.selected) == [false, true, false])
        try Self.press(Self.up.0, keyCode: Self.up.1, in: window)
        try Self.press(Self.up.0, keyCode: Self.up.1, in: window)
        #expect(try Self.rows(window).map(\.selected) == [false, false, true])
        // The keyboard never left the message field.
        #expect(window.firstResponder is NSTextView)
    }

    @Test func returnSendsACommandThatTakesNothing() throws {
        let (window, box) = try Self.host()
        try Self.type("/co", in: window)
        try Self.press(Self.down.0, keyCode: Self.down.1, in: window)
        try Self.press(Self.returnKey.0, keyCode: Self.returnKey.1, in: window)
        #expect(box.sent == ["/context"])
    }

    @Test func returnOnACommandThatTakesArgumentsLeavesRoomForThem() throws {
        let (window, box) = try Self.host()
        try Self.type("/mo", in: window)
        try Self.press(Self.returnKey.0, keyCode: Self.returnKey.1, in: window)
        #expect(box.sent.isEmpty)
        #expect(box.draft == "/model ")
    }

    @Test func tabCompletesWithoutSending() throws {
        let (window, box) = try Self.host()
        try Self.type("/cos", in: window)
        try Self.press(Self.tab.0, keyCode: Self.tab.1, in: window)
        #expect(box.sent.isEmpty)
        #expect(box.draft == "/cost ")
        #expect(window.firstResponder is NSTextView)
    }

    @Test func escapeClosesTheListAndTypingReopensIt() throws {
        let (window, _) = try Self.host()
        try Self.type("/co", in: window)
        try Self.press(Self.escape.0, keyCode: Self.escape.1, in: window)
        #expect(try Self.rows(window).isEmpty)
        try Self.type("m", in: window)
        #expect(try Self.rows(window).map(\.label).first?.hasPrefix("/compact") == true)
    }

    /// With no list showing, Return sends the message as before.
    @Test func returnStillSendsAPlainMessage() throws {
        let (window, box) = try Self.host()
        try Self.type("Hello", in: window)
        try Self.press(Self.returnKey.0, keyCode: Self.returnKey.1, in: window)
        #expect(box.sent == ["Hello"])
    }

    /// Escape closes the list for that draft only: once the field changes,
    /// typing the same command again lists it again.
    @Test func retypingAfterEscapeListsAgain() throws {
        let (window, _) = try Self.host()
        try Self.type("/co", in: window)
        try Self.press(Self.escape.0, keyCode: Self.escape.1, in: window)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("", replacementRange: editor.selectedRange())
        AccessibilityHost.settle(try #require(window.contentView))
        try Self.type("/co", in: window)
        #expect(try !Self.rows(window).isEmpty)
    }

    /// What VoiceOver is asked to say, in order.
    final class Heard {
        var lines: [(String, Announcer.Urgency)] = []
        var token = 0
        @MainActor func stop() { Announcer.stopListening(token) }
    }

    /// Only the picker's lines: other suites announce in parallel through
    /// the same hook.
    static func listen() -> Heard {
        let heard = Heard()
        heard.token = Announcer.listen { text, urgency in
            if text.hasPrefix("/") || text.contains(" commands.") || text.hasPrefix("No commands") {
                heard.lines.append((text, urgency))
            }
        }
        return heard
    }

    static func wait(_ seconds: Double, in window: NSWindow) throws {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        AccessibilityHost.settle(try #require(window.contentView))
    }

    @Test func typingPausesThenTheCountAndFirstMatchAreSaid() async throws {
        let (window, _) = try Self.host()
        let heard = Self.listen()
        defer { heard.stop() }
        try Self.type("/co", in: window)
        // Async, so the field's own wait can run on the main actor meanwhile.
        // Polls with a generous ceiling: the hosted suites hold the main
        // actor for seconds at a time, and this announcement needs it.
        let deadline = ContinuousClock.now + SlashCommandSearch.announcementDelay * 20
        while heard.lines.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(heard.lines.map(\.0) == ["3 commands. /compact, Free up context by summarizing the conversation so far"])
        #expect(heard.lines.allSatisfy { $0.1 == .urgent })
    }

    @Test func eachArrowSaysTheHighlightedCommand() throws {
        let (window, _) = try Self.host()
        try Self.type("/co", in: window)
        let heard = Self.listen()
        defer { heard.stop() }
        try Self.press(Self.down.0, keyCode: Self.down.1, in: window)
        #expect(heard.lines.first?.0 == "/context, Visualize current context usage")
        #expect(heard.lines.first?.1 == .urgent)
    }

    /// Removing an attachment keeps the keyboard and VoiceOver in the
    /// message field: the pressed button goes away, and focus fell to the
    /// toolbar (heard live). VoiceOver hears what was removed.
    @Test func removingAnAttachmentReturnsToTheMessageField() async throws {
        let box = Box()
        let image = ImageAttachment(name: "river.png", mediaType: "image/png", data: Data([0]))
        let (window, view) = AccessibilityHost.window(
            hosting: Host(box: box, commands: [], initialAttachments: [image]), size: NSSize(width: 700, height: 400)
        )
        AccessibilityHost.settle(view)
        let heard = Heard()
        heard.token = Announcer.listen { text, _ in if text.contains("river.png") { heard.lines.append((text, .routine)) } }
        defer { heard.stop() }
        let remove = try #require(AccessibilityHost.descendants(of: view).first {
            AccessibilityHost.label($0) == "Remove river.png" && AccessibilityHost.role($0) == .button
        })
        // Where VoiceOver's press leaves keyboard focus: on the button.
        window.makeFirstResponder(nil)
        _ = (remove as AnyObject).accessibilityPerformPress?()
        AccessibilityHost.settle(view)
        #expect(window.firstResponder is NSTextView, "focus: \(String(describing: window.firstResponder))")
        let deadline = ContinuousClock.now + .seconds(20)
        while heard.lines.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(heard.lines.map(\.0) == ["Removed river.png."])
    }

    /// Return never swaps what was typed for a command found only by its
    /// description: "/summ" names no command, so it's sent as typed, not
    /// turned into /compact (whose description says "summarizing").
    @Test func returnSendsWhatWasTypedWhenOnlyADescriptionMatches() throws {
        let (window, box) = try Self.host()
        try Self.type("/summ", in: window)
        #expect(try Self.rows(window).map(\.label).first?.hasPrefix("/compact") == true)
        try Self.press(Self.returnKey.0, keyCode: Self.returnKey.1, in: window)
        #expect(box.sent == ["/summ"])
    }

    /// Once the arrows have moved, the count isn't said: it would cut in
    /// and name the first match rather than the highlighted one.
    @Test func arrowingBeforeThePauseSkipsTheCount() async throws {
        let (window, _) = try Self.host()
        let heard = Self.listen()
        defer { heard.stop() }
        try Self.type("/co", in: window)
        try Self.press(Self.down.0, keyCode: Self.down.1, in: window)
        let deadline = ContinuousClock.now + SlashCommandSearch.announcementDelay * 3
        while ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(heard.lines.map(\.0) == ["/context, Visualize current context usage"])
    }

    /// Until the CLI is ready nothing is offered: a command chosen then
    /// replaced the draft, and sending it failed silently.
    @Test func noListUntilTheCLIIsReady() throws {
        let box = Box()
        let (window, view) = AccessibilityHost.window(
            hosting: Host(box: box, commands: Self.commands, isReady: false), size: NSSize(width: 700, height: 400)
        )
        AccessibilityHost.settle(view)
        try Self.type("/co", in: window)
        #expect(try Self.rows(window).isEmpty)
        try Self.press(Self.returnKey.0, keyCode: Self.returnKey.1, in: window)
        // Return falls through to sending what was typed (the app's send
        // waits for the CLI); no command replaced it.
        #expect(box.sent == ["/co"])
    }

    /// After just "/", Return still chooses the highlighted command: every
    /// command's name matches an empty query.
    @Test func returnAfterASlashAloneChoosesTheHighlighted() throws {
        let (window, box) = try Self.host()
        try Self.type("/", in: window)
        try Self.press(Self.down.0, keyCode: Self.down.1, in: window)
        try Self.press(Self.returnKey.0, keyCode: Self.returnKey.1, in: window)
        // Sorted by name: compact, context, cost, model; Down lands on context.
        #expect(box.sent == ["/context"])
    }

    /// When the list goes and comes back for the same draft (the CLI
    /// restarting), the highlight starts at the top again, so the count
    /// is said and Return picks what's shown first.
    @Test func aListThatReturnsStartsAtTheTop() throws {
        let (window, box) = try Self.host()
        try Self.type("/co", in: window)
        try Self.press(Self.down.0, keyCode: Self.down.1, in: window)
        try Self.press(Self.down.0, keyCode: Self.down.1, in: window)
        box.setReady(false)
        AccessibilityHost.settle(try #require(window.contentView))
        #expect(try Self.rows(window).isEmpty)
        box.setReady(true)
        AccessibilityHost.settle(try #require(window.contentView))
        #expect(try Self.rows(window).map(\.selected) == [true, false, false])
    }
}
