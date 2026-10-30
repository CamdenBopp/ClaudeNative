import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// A Claude reply as VoiceOver reaches it: a group named "Claude" holding
/// one element per Markdown block, in the real TranscriptView, hosted.
@MainActor
struct ReplyBlockAccessibilityTests {
    static let reply = """
    # Getting started

    See [the Swift site](https://swift.org) for more.

    ## Steps

    1. Install it
    2. Build it
    3. Run it

    ```swift
    let a = 1
    let b = 2
    print(a + b)
    ```

    > A quoted line

    | Name | Size |
    | --- | --- |
    | a | 1 |

    ---

    Done.
    """

    @MainActor
    final class Hosted {
        let window: NSWindow
        let host: NSHostingView<TranscriptView>

        init(_ text: String, isWorking: Bool = false) {
            (window, host) = AccessibilityHost.window(
                hosting: TranscriptView(
                    transcript: Self.transcript(text), revision: 0, workingDirectory: nil, isWorking: isWorking
                ),
                size: NSSize(width: 800, height: 900)
            )
        }

        static func transcript(_ reply: String) -> Transcript {
            Transcript(restoring: [
                TranscriptEntry(id: "u", kind: .user, text: "Show me Markdown"),
                TranscriptEntry(id: "r", kind: .assistant, text: reply),
            ])
        }

        func show(_ text: String, isWorking: Bool = false, textScale: Double = TextScale.standard.factor) {
            host.rootView = TranscriptView(
                transcript: Self.transcript(text), revision: 0, workingDirectory: nil, isWorking: isWorking,
                textScale: textScale
            )
            AccessibilityHost.settle(host)
        }

        var conversation: AnyObject? {
            AccessibilityHost.descendants(of: window).first {
                AccessibilityHost.role($0) == .scrollArea && AccessibilityHost.label($0) == "Conversation"
            }
        }

        var replyRow: AnyObject? {
            conversation.flatMap { AccessibilityHost.children($0).last { AccessibilityHost.role($0) == .group } }
        }

        var blocks: [AnyObject] { replyRow.map(AccessibilityHost.children) ?? [] }
    }

    static func describe(_ element: AnyObject) -> String {
        let role = AccessibilityHost.role(element)?.rawValue ?? "?"
        let label = AccessibilityHost.label(element).map { " [\($0)]" } ?? ""
        let value = AccessibilityHost.value(element).map { " = \($0)" } ?? ""
        return role + label + value
    }

    @Test func aReplyIsAGroupNamedClaudeWithOneElementPerBlock() throws {
        let hosted = Hosted(Self.reply)
        let row = try #require(hosted.replyRow)
        #expect(AccessibilityHost.label(row) == "Claude")
        #expect(AccessibilityHost.value(row) == nil)
        #expect(hosted.blocks.map(Self.describe) == [
            "AXHeading [Getting started]",
            "AXStaticText = See the Swift site for more.",
            "AXLink [the Swift site]",
            "AXHeading [Steps]",
            "AXList",
            "AXStaticText = Swift code, 3 lines: let a = 1\nlet b = 2\nprint(a + b)",
            "AXStaticText [Quote] = A quoted line",
            "AXGroup [Table, 2 rows]",
            "AXStaticText = Done.",
        ])
        // Every other row is still one static text with no children.
        let others = try #require(hosted.conversation.map(AccessibilityHost.children))
            .filter { AccessibilityHost.role($0) != .scrollBar && $0 !== row }
        #expect(others.map(AccessibilityHost.role) == [.staticText])
        #expect(others.allSatisfy { AccessibilityHost.children($0).isEmpty })
    }

    @Test func headingsCarryTheirLevel() throws {
        let hosted = Hosted(Self.reply)
        let headings = hosted.blocks.filter { AccessibilityHost.role($0)?.rawValue == "AXHeading" }
        let levels = headings.map { ($0 as? NSObject)?.accessibilityAttributeValue(.init(rawValue: "AXHeadingLevel")) as? Int }
        #expect(levels == [1, 2])
        #expect(headings.allSatisfy { ($0 as? NSAccessibilityElement)?.accessibilityRoleDescription() == "heading" })
    }

    @Test func aListHasOneItemPerEntryKeepingNumbers() throws {
        let hosted = Hosted(Self.reply)
        let list = try #require(hosted.blocks.first { AccessibilityHost.role($0) == .list })
        #expect((list as? NSAccessibilityElement)?.accessibilitySubrole() == .contentList)
        let items = AccessibilityHost.children(list)
        #expect(items.map(Self.describe) == [
            "AXStaticText = 1. Install it", "AXStaticText = 2. Build it", "AXStaticText = 3. Run it",
        ])
        let bullets = Hosted("- Milk\n- Eggs, [fresh](https://example.com/eggs)\n")
        let bulletList = try #require(bullets.blocks.first)
        #expect(AccessibilityHost.children(bulletList).map(Self.describe) == [
            "AXStaticText = Milk", "AXStaticText = Eggs, fresh", "AXLink [fresh]",
        ])
    }

    @Test func aTableReadsOneRowPerElement() throws {
        let hosted = Hosted(Self.reply)
        let table = try #require(hosted.blocks.first { AccessibilityHost.label($0) == "Table, 2 rows" })
        #expect(AccessibilityHost.children(table).map(Self.describe) == [
            "AXStaticText = Row 1: Name, Size", "AXStaticText = Row 2: a, 1",
        ])
    }

    @Test func aTableKeepsItsLinksReachableAndItsRowsStable() throws {
        let table = "| Site | Note |\n| --- | --- |\n| [Swift](https://swift.org) | Read the docs |\n"
        let hosted = Hosted(table, isWorking: true)
        let group = try #require(hosted.blocks.first)
        let before = AccessibilityHost.children(group)
        #expect(before.map(Self.describe) == [
            "AXStaticText = Row 1: Site, Note",
            "AXStaticText = Row 2: Swift, Read the docs",
            "AXLink [Swift]",
        ])
        hosted.show(table + "| More | Another row |\n")
        let after = AccessibilityHost.children(group)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
        let rowFrames = after.filter { AccessibilityHost.role($0) == .staticText }.map(Self.frame)
        #expect(rowFrames.count == 3)
        for (upper, lower) in zip(rowFrames, rowFrames.dropFirst()) {
            #expect(lower.maxY <= upper.minY + 1)
        }
    }

    @Test func aCodeBlockCopiesItsCodeAndTheMessageActionsStayReachable() throws {
        let hosted = Hosted(Self.reply)
        let code = try #require(hosted.blocks.first { AccessibilityHost.value($0)?.hasPrefix("Swift code, 3 lines: ") == true })
        let names = AccessibilityHost.customActions(code).map(\.name)
        #expect(names == ["Copy code", "Copy message", "Mark message"])
        let board = NSPasteboard.withUniqueName()
        Clipboard.board = board
        defer { Clipboard.board = .general; board.releaseGlobally() }
        _ = AccessibilityHost.customActions(code).first?.handler?()
        #expect(board.string(forType: .string) == "let a = 1\nlet b = 2\nprint(a + b)")
        // The group keeps every action it had.
        let row = try #require(hosted.replyRow)
        let rowNames = AccessibilityHost.customActions(row).map(\.name)
        #expect(Array(rowNames.prefix(2)) == ["Copy message", "Mark message"])
        #expect(rowNames.contains("Open link: the Swift site"))
        #expect(rowNames.contains("Copy code block"))
    }

    @Test func markingNamesTheGroupClaudeMarked() throws {
        let hosted = Hosted(Self.reply)
        let row = try #require(hosted.replyRow)
        let paragraph = try #require(hosted.blocks.dropFirst().first)
        let mark = try #require(AccessibilityHost.customActions(paragraph).first { $0.name == "Mark message" })
        #expect(mark.handler?() == true)
        #expect(AccessibilityHost.label(row) == "Claude, marked")
        #expect(AccessibilityHost.customActions(paragraph).contains { $0.name == "Remove mark" })
    }

    @Test func anOpenCodeBlockSaysItIsStillReceiving() throws {
        let hosted = Hosted("Here:\n\n```swift\nlet a = 1\n", isWorking: true)
        let code = try #require(hosted.blocks.last)
        #expect(AccessibilityHost.value(code)?.hasPrefix("Swift code, 1 line, still receiving: ") == true)
        hosted.show("Here:\n\n```swift\nlet a = 1\n```\n", isWorking: false)
        #expect(AccessibilityHost.value(code)?.hasPrefix("Swift code, 1 line: ") == true)
        #expect(hosted.blocks.last === code)
    }

    @Test func streamingKeepsEachBlocksElement() throws {
        let start = "# Title\n\nFirst paragraph.\n\nSecond para"
        let hosted = Hosted(start, isWorking: true)
        let before = hosted.blocks
        #expect(before.count == 3)
        // More of the last paragraph: the same elements, the new words.
        hosted.show(start + "graph grows", isWorking: true)
        let grown = hosted.blocks
        #expect(grown.count == 3)
        #expect(zip(before, grown).allSatisfy { $0 === $1 })
        #expect(AccessibilityHost.value(grown[2]) == "Second paragraph grows")
        // A new block: the earlier ones are still the same elements.
        hosted.show(start + "graph grows\n\n- one\n- two", isWorking: true)
        let added = hosted.blocks
        #expect(added.count == 4)
        #expect(zip(before, added).allSatisfy { $0 === $1 })
        let list = try #require(added.last)
        let firstItem = try #require(AccessibilityHost.children(list).first)
        hosted.show(start + "graph grows\n\n- one\n- two\n- three", isWorking: true)
        #expect(hosted.blocks.last === list)
        #expect(AccessibilityHost.children(list).first === firstItem)
        #expect(AccessibilityHost.children(list).count == 3)
        // Finished, still the same elements.
        hosted.show(start + "graph grows\n\n- one\n- two\n- three", isWorking: false)
        #expect(zip(added, hosted.blocks).allSatisfy { $0 === $1 })
    }

    static func frame(_ element: AnyObject) -> NSRect {
        (element as? NSAccessibilityElement)?.accessibilityFrame() ?? .zero
    }

    @Test func framesSitInsideTheRowInReadingOrderAtAnyTextSize() throws {
        let hosted = Hosted(Self.reply)
        let row = try #require(hosted.replyRow as? MessageRowView)
        let blocks = hosted.blocks

        func check(_ blocks: [AnyObject]) {
            let rowFrame = row.accessibilityFrame()
            let frames = blocks.filter { AccessibilityHost.role($0) != .link }.map(Self.frame)
            for (element, frame) in zip(blocks, frames) {
                #expect(frame.height > 0 && frame.width > 0, "\(Self.describe(element))")
                #expect(rowFrame.insetBy(dx: -1, dy: -1).contains(frame), "\(Self.describe(element)) \(frame) not in \(rowFrame)")
            }
            // Screen coordinates rise upward: each block is below the one before.
            for (upper, lower) in zip(frames, frames.dropFirst()) {
                #expect(lower.maxY <= upper.minY + 1, "\(lower) not below \(upper)")
            }
            // A link sits on its paragraph's line, inside it.
            if let link = blocks.first(where: { AccessibilityHost.role($0) == .link }) {
                #expect(frames[1].insetBy(dx: -1, dy: -1).contains(Self.frame(link)))
                #expect(Self.frame(link).width < frames[1].width)
            }
            // The code block's frame is its card.
            if let card = row.codeCardFrames.first, let window = row.window,
               let code = blocks.first(where: { AccessibilityHost.value($0)?.hasPrefix("Swift code, 3 lines: ") == true }) {
                let cardOnScreen = window.convertToScreen(row.convert(card, to: nil))
                #expect(abs(Self.frame(code).minY - cardOnScreen.minY) < 1 && abs(Self.frame(code).maxY - cardOnScreen.maxY) < 1,
                        "\(Self.frame(code)) vs card \(cardOnScreen)")
            }
        }

        check(blocks)
        let standardHeading = Self.frame(blocks[0]).height
        let bigger = try #require(TextScale.standard.bigger)
        hosted.show(Self.reply, textScale: bigger.factor)
        let rescaled = hosted.blocks
        #expect(zip(blocks, rescaled).allSatisfy { $0 === $1 })
        #expect(Self.frame(rescaled[0]).height > standardHeading)
        check(rescaled)
    }

    @Test func linksRotorLandsOnEachLinkAndStopsAtTheEnd() throws {
        let hosted = Hosted("See [Swift](https://swift.org) here.\n\nAnd [the docs](https://developer.apple.com) there.")
        let conversation = try #require(hosted.conversation)
        let rotor = try #require(AccessibilityHost.customRotors(conversation).first { $0.type == .link })
        let delegate = try #require(rotor.itemSearchDelegate)
        func search(_ current: NSAccessibilityCustomRotor.ItemResult?, _ direction: NSAccessibilityCustomRotor.SearchDirection)
            -> NSAccessibilityCustomRotor.ItemResult? {
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.currentItem = current
            parameters.searchDirection = direction
            return delegate.rotor(rotor, resultFor: parameters)
        }
        let first = try #require(search(nil, .next))
        #expect(first.customLabel == "Swift")
        #expect((first.targetElement as? NSAccessibilityElement)?.accessibilityRole() == .link)
        let second = try #require(search(first, .next))
        #expect(second.customLabel == "the docs")
        #expect(search(second, .next) == nil)
        #expect(search(first, .previous) == nil)
    }

    /// Links inside a list are stops too, each in order, between the links
    /// before and after the list.
    @Test func linksRotorReachesLinksInsideAList() throws {
        let hosted = Hosted("Start at [one](https://one.example).\n\n- See [two](https://two.example)\n- and [three](https://three.example)\n\nEnd at [four](https://four.example).")
        let conversation = try #require(hosted.conversation)
        let rotor = try #require(AccessibilityHost.customRotors(conversation).first { $0.type == .link })
        let delegate = try #require(rotor.itemSearchDelegate)
        var labels: [String] = []
        var current: NSAccessibilityCustomRotor.ItemResult?
        for _ in 0..<6 {
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.currentItem = current
            parameters.searchDirection = .next
            guard let next = delegate.rotor(rotor, resultFor: parameters) else { break }
            labels.append(next.customLabel ?? "")
            current = next
        }
        #expect(labels == ["one", "two", "three", "four"])
    }

    @Test func codeBlocksRotorLandsOnEachCodeBlockAndStopsAtTheEnd() throws {
        let hosted = Hosted("```sh\nls\n```\n\nThen:\n\n```swift\nlet a = 1\nlet b = 2\n```")
        let conversation = try #require(hosted.conversation)
        let rotor = try #require(AccessibilityHost.customRotors(conversation).first { $0.label == "Code Blocks" })
        let delegate = try #require(rotor.itemSearchDelegate)
        func search(_ current: NSAccessibilityCustomRotor.ItemResult?, _ direction: NSAccessibilityCustomRotor.SearchDirection)
            -> NSAccessibilityCustomRotor.ItemResult? {
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.currentItem = current
            parameters.searchDirection = direction
            return delegate.rotor(rotor, resultFor: parameters)
        }
        let codes = hosted.blocks.filter { AccessibilityHost.value($0)?.contains(" code, ") == true }
        #expect(codes.count == 2)
        let first = try #require(search(nil, .next))
        #expect(first.targetElement === codes[0])
        #expect(first.customLabel == "Shell code, 1 line")
        let second = try #require(search(first, .next))
        #expect(second.targetElement === codes[1])
        #expect(second.customLabel == "Swift code, 2 lines")
        #expect(search(second, .next) == nil)
        #expect(search(first, .previous) == nil)
        #expect(search(second, .previous)?.targetElement === codes[0])
    }

    @Test func headingsRotorLandsOnEachHeadingAndStopsAtTheEnd() throws {
        let hosted = Hosted(Self.reply)
        let conversation = try #require(hosted.conversation)
        let rotor = try #require(AccessibilityHost.customRotors(conversation).first { $0.type == .heading })
        let delegate = try #require(rotor.itemSearchDelegate)
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .next
        var landed: [String] = []
        while let result = delegate.rotor(rotor, resultFor: parameters) {
            landed.append(AccessibilityHost.label(result.targetElement as AnyObject) ?? "")
            parameters.currentItem = result
            if landed.count > 5 { break }
        }
        #expect(landed == ["Getting started", "Steps"])
        // From the list, between the two, Previous is "Steps".
        let list = try #require(hosted.blocks.first { AccessibilityHost.role($0) == .list } as? NSAccessibilityElementProtocol)
        parameters.currentItem = NSAccessibilityCustomRotor.ItemResult(targetElement: list)
        parameters.searchDirection = .previous
        let previous = try #require(delegate.rotor(rotor, resultFor: parameters))
        #expect(AccessibilityHost.label(previous.targetElement as AnyObject) == "Steps")
    }

    @Test func messagesRotorFromInsideAReplyMovesToTheNextMessage() throws {
        let hosted = Hosted(Self.reply)
        let conversation = try #require(hosted.conversation)
        let rotor = try #require(AccessibilityHost.customRotors(conversation).first { $0.label == "Messages" })
        let delegate = try #require(rotor.itemSearchDelegate)
        let row = try #require(hosted.replyRow)
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .previous
        let heading = try #require(hosted.blocks.first as? NSAccessibilityElementProtocol)
        parameters.currentItem = NSAccessibilityCustomRotor.ItemResult(targetElement: heading)
        let previous = try #require(delegate.rotor(rotor, resultFor: parameters))
        #expect(AccessibilityHost.value(previous.targetElement as AnyObject) == "You: Show me Markdown")
        parameters.currentItem = nil
        parameters.searchDirection = .next
        let first = try #require(delegate.rotor(rotor, resultFor: parameters))
        parameters.currentItem = first
        let next = try #require(delegate.rotor(rotor, resultFor: parameters))
        #expect(next.targetElement === row)
        #expect(next.customLabel?.hasPrefix("Claude: Getting started") == true)
    }
}
