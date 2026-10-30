import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// The conversation as VoiceOver reaches it: the real TranscriptView hosted
/// in a window, its accessibility tree walked from the window down.
@MainActor
struct TranscriptAccessibilityTreeTests {
    /// A real capture with one row of each kind VoiceOver hears differently:
    /// your message, a finished tool call, a finished thought, a reply.
    static let fixture = "real_permission_allow"

    @MainActor
    final class Hosted {
        let window: NSWindow
        let host: NSHostingView<TranscriptView>

        init(_ transcript: Transcript) {
            (window, host) = AccessibilityHost.window(
                hosting: TranscriptView(transcript: transcript, revision: 0, workingDirectory: nil, isWorking: false),
                size: NSSize(width: 800, height: 600)
            )
        }

        func show(_ transcript: Transcript, textScale: Double = TextScale.standard.factor) {
            host.rootView = TranscriptView(
                transcript: transcript, revision: 0, workingDirectory: nil, isWorking: false, textScale: textScale
            )
            AccessibilityHost.settle(host)
        }

        /// The scroll area VoiceOver calls "Conversation".
        var conversation: AnyObject? {
            AccessibilityHost.descendants(of: window).first {
                AccessibilityHost.role($0) == .scrollArea && AccessibilityHost.label($0) == "Conversation"
            }
        }

        /// The conversation's direct accessibility children, less its scroll bar.
        var rows: [AnyObject] {
            guard let conversation else { return [] }
            return AccessibilityHost.children(conversation).filter { AccessibilityHost.role($0) != .scrollBar }
        }
    }

    static func value(_ element: AnyObject) -> String {
        AccessibilityHost.value(element) ?? ""
    }

    /// VoiceOver moves by the navigation order, not the children. AppKit
    /// sorted it by position, so your right-aligned message came after the
    /// tool row drawn below it, and at some widths the reply came before
    /// the tool: VO-Right from "You" skipped the tool row (seen live on
    /// 2026-10-27, and on the build before that day's changes).
    @Test(arguments: [500.0, 720.0, 1100.0])
    func voiceOverMovesThroughRowsInConversationOrder(width: Double) throws {
        var tool = TranscriptEntry(id: "tool:1", kind: .tool(name: "Bash", status: .succeeded), text: "Bash: ls -la")
        tool.output = "total 8"
        let hosted = Hosted(Transcript(restoring: [
            TranscriptEntry(id: "user:1", kind: .user, text: "Use the Bash tool to run: ls -la. Then reply with just ok."),
            tool,
            TranscriptEntry(id: "assistant:1", kind: .assistant, text: "ok"),
        ]))
        hosted.window.setContentSize(NSSize(width: width, height: 600))
        AccessibilityHost.settle(hosted.host)
        let conversation = try #require(hosted.conversation as? NSView)
        // Read as an assistive app does, through the attribute.
        let attribute = NSAccessibility.Attribute(rawValue: "AXChildrenInNavigationOrder")
        let order = ((conversation.accessibilityAttributeValue(attribute) as? [Any]) ?? [])
            .map { $0 as AnyObject }
            .filter { AccessibilityHost.role($0) != .scrollBar }
        #expect(order.map(AccessibilityHost.role) == [.staticText, .staticText, .group])
        #expect(order.map(Self.value) == hosted.rows.map(Self.value), "\(order.map(Self.value))")
    }

    /// At every level, down into a reply with a heading, a nested list, a
    /// code block, a table and a quote, the navigation order is the
    /// children's order.
    @Test(arguments: [500.0, 1100.0])
    func everyContainerInAReplyKeepsReadingOrder(width: Double) throws {
        let markdown = """
        ## Plan

        1. First step
           - nested detail
        2. Second step

        ```swift
        let x = 1
        ```

        | Name | Value |
        | --- | --- |
        | a | 1 |

        > A quoted line.

        Done.
        """
        let hosted = Hosted(Transcript(restoring: [
            TranscriptEntry(id: "user:1", kind: .user, text: "Show me everything."),
            TranscriptEntry(id: "tool:1", kind: .tool(name: "Read", status: .succeeded), text: "Read: notes.md"),
            TranscriptEntry(id: "assistant:1", kind: .assistant, text: markdown),
        ]))
        hosted.window.setContentSize(NSSize(width: width, height: 900))
        AccessibilityHost.settle(hosted.host)
        let attribute = NSAccessibility.Attribute(rawValue: "AXChildrenInNavigationOrder")
        func check(_ element: AnyObject, depth: Int) {
            let children = AccessibilityHost.children(element).filter { AccessibilityHost.role($0) != .scrollBar }
            if let view = element as? NSObject,
               let order = (view.accessibilityAttributeValue(attribute) as? [Any])?.map({ $0 as AnyObject })
                .filter({ AccessibilityHost.role($0) != .scrollBar }), !order.isEmpty {
                #expect(order.map(Self.value) == children.map(Self.value),
                        "\(AccessibilityHost.role(element).map { $0.rawValue } ?? "?") \(AccessibilityHost.label(element) ?? "")")
            }
            guard depth < 20 else { return }
            for child in children { check(child, depth: depth + 1) }
        }
        check(try #require(hosted.conversation), depth: 0)
    }

    @Test func eachEntryIsOneStaticTextThatSpeaksItsTitleFirstExceptAReply() throws {
        let transcript = try Fixtures.replay(Self.fixture)
        let hosted = Hosted(transcript)
        let rows = hosted.rows
        #expect(rows.count == transcript.entries.count)
        #expect(rows.map(AccessibilityHost.role) == [.staticText, .staticText, .staticText, .group])
        for row in rows.dropLast() {
            #expect(AccessibilityHost.children(row).isEmpty, "\(Self.value(row))")
        }
        // Pinned from the capture, so a change to the fixture or the wording
        // shows up here rather than passing silently.
        let titles = ["You", "Tool, done", "Thought", "Claude"]
        #expect(transcript.entries.map { RowWording.spokenTitle(of: $0) } == titles)
        for (row, title) in zip(rows.dropLast(), titles) {
            let value = Self.value(row)
            #expect(value == title || value.hasPrefix("\(title): "), "\(value)")
        }
        // The reply is a group named "Claude"; its one paragraph holds the
        // text as drawn, without the capture's backticks.
        let reply = try #require(rows.last)
        #expect(AccessibilityHost.label(reply) == "Claude")
        #expect(AccessibilityHost.value(reply) == nil)
        #expect(AccessibilityHost.children(reply).map { AccessibilityHost.role($0) } == [.staticText])
        #expect(AccessibilityHost.children(reply).map(Self.value)
            == ["Created hello.txt in the current directory containing hi."])
    }

    @Test func markMessageActionMarksTheRowItIsOn() throws {
        let hosted = Hosted(try Fixtures.replay(Self.fixture))
        let reply = try #require(hosted.rows.last)
        #expect(AccessibilityHost.label(reply) == "Claude")
        // Other actions may sit beside it; only this one is looked for.
        let mark = try #require(AccessibilityHost.customActions(reply).first { $0.name == "Mark message" })
        #expect(mark.handler?() == true)
        #expect(AccessibilityHost.label(reply) == "Claude, marked")
        #expect(AccessibilityHost.customActions(reply).contains { $0.name == "Remove mark" })
        // Only that row changed.
        #expect(hosted.rows.dropLast().allSatisfy { !Self.value($0).contains(", marked") })
    }

    @Test func rowsKeepTheirIdentityAsTheConversationGrowsAndRescales() throws {
        var transcript = try Fixtures.replay(Self.fixture)
        let hosted = Hosted(transcript)
        let before = hosted.rows
        #expect(before.count == transcript.entries.count)

        transcript.appendUser("And another thing")
        hosted.show(transcript)
        let grown = hosted.rows
        #expect(grown.count == before.count + 1)
        #expect(zip(before, grown).allSatisfy { $0 === $1 })

        let bigger = try #require(TextScale.standard.bigger)
        hosted.show(transcript, textScale: bigger.factor)
        let rescaled = hosted.rows
        #expect(rescaled.count == grown.count)
        #expect(zip(grown, rescaled).allSatisfy { $0 === $1 })
    }

    /// `real_permission_allow` up to its Write call starting, `ago` seconds
    /// before now, then the rest of the capture.
    static func runningWrite(startedAgo ago: TimeInterval) throws -> (running: Transcript, finished: Transcript) {
        var transcript = Transcript()
        transcript.appendUser("prompt")
        var running: Transcript?
        let started = Date().addingTimeInterval(-ago)
        for event in try Fixtures.events(Self.fixture) {
            transcript.apply(event, at: started)
            if running == nil, transcript.entries.contains(where: { $0.kind == .tool(name: "Write", status: .running) }) {
                running = transcript
            }
        }
        return (try #require(running), transcript)
    }

    @Test func runningToolRowTellsItsTimeInPlaceUntilItFinishes() throws {
        let (running, finished) = try Self.runningWrite(startedAgo: 42.5)
        let hosted = Hosted(running)
        let toolRow = try #require(hosted.rows.first { Self.value($0).hasPrefix("Tool, running") })
        #expect(Self.value(toolRow).hasPrefix("Tool, running 42 seconds: Write: "), "\(Self.value(toolRow))")

        // The timer's work, at a moment past the first minute: the same
        // element, still one static text, says the new time.
        let rowView = toolRow as? MessageRowView
        let view = try #require(rowView)
        let started = try #require(view.runningSince)
        view.showElapsed(at: started.addingTimeInterval(67))
        let ticked = try #require(hosted.rows.first { Self.value($0).hasPrefix("Tool, running") })
        let sameElement = ticked === toolRow
        #expect(sameElement)
        #expect(Self.value(toolRow).hasPrefix("Tool, running 1 minute 5 seconds: Write: "), "\(Self.value(toolRow))")
        #expect(AccessibilityHost.children(toolRow).isEmpty)

        // Done, it reads as any finished tool, and the timer has nothing to move.
        hosted.show(finished)
        let stillThere = hosted.rows.contains { $0 === toolRow }
        #expect(stillThere)
        #expect(Self.value(toolRow).hasPrefix("Tool, done: Write: "), "\(Self.value(toolRow))")
        #expect(view.runningSince == nil)
        view.showElapsed(at: started.addingTimeInterval(200))
        #expect(Self.value(toolRow).hasPrefix("Tool, done: Write: "), "\(Self.value(toolRow))")
    }

    @Test func conversationOffersItsRotors() throws {
        let hosted = Hosted(try Fixtures.replay(Self.fixture))
        let conversation = try #require(hosted.conversation)
        let rotors = AccessibilityHost.customRotors(conversation)
        #expect(rotors.filter { $0.type == .custom }.map(\.label) == [
            "Messages", "Your Messages", "Tool Calls", "Marked Messages", "Code Blocks",
        ])
        // VoiceOver's own Headings rotor, filled by the conversation.
        #expect(rotors.filter { $0.type != .custom }.map(\.type) == [.heading, .link])
    }

    @Test func toolCallsRotorFindsTheToolRowAndStopsAtTheEnd() throws {
        let hosted = Hosted(try Fixtures.replay(Self.fixture))
        let conversation = try #require(hosted.conversation)
        let rotor = try #require(AccessibilityHost.customRotors(conversation).first { $0.label == "Tool Calls" })
        let delegate = try #require(rotor.itemSearchDelegate)
        let toolRow = try #require(hosted.rows.first { Self.value($0).hasPrefix("Tool, done") })

        func search(
            from current: NSAccessibilityCustomRotor.ItemResult?,
            _ direction: NSAccessibilityCustomRotor.SearchDirection
        ) -> NSAccessibilityCustomRotor.ItemResult? {
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.currentItem = current
            parameters.searchDirection = direction
            return delegate.rotor(rotor, resultFor: parameters)
        }

        let first = try #require(search(from: nil, .next))
        #expect(first.targetElement === toolRow)
        #expect(first.customLabel == Self.value(toolRow))
        // One tool call: past it in either direction there is nothing, not
        // the same row again.
        #expect(search(from: first, .next) == nil)
        #expect(search(from: first, .previous) == nil)
    }
}
