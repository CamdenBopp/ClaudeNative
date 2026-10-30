import AppKit
import ChatMarkdownAppKit
import ChatMarkdownCore
import ClaudeNativeCore

/// One part of a Claude reply as VoiceOver reaches it: a heading, a
/// paragraph, a list and its items, a code block, a quote, a table and its
/// rows, or a link. The reply's row draws the text; these only describe it.
///
/// The frame is worked out each time it's asked for, from the row's kept
/// layout, so it follows scrolling, resizing and text size changes.
class ReplyElement: NSAccessibilityElement, NSAccessibilityElementProtocol, @unchecked Sendable {
    /// How the frame hugs the element's text.
    enum Shape {
        /// The column's width, from the top of the first line to the bottom
        /// of the last.
        case lines
        /// Just around the glyphs, for a link.
        case glyphs
        /// The card drawn behind a code block.
        case card
    }

    // Every property is only touched on the main thread, where AppKit asks
    // for accessibility and where the row updates the reply.
    nonisolated(unsafe) weak var row: MessageRowView?
    nonisolated(unsafe) weak var parentElement: AnyObject?
    var range: NSRange
    var shape: Shape
    var role: NSAccessibility.Role
    var subrole: NSAccessibility.Subrole?
    var roleDescription: String?
    var label: String?
    var value: String?
    /// A heading's level, 1 to 6, as SwiftUI's headings report it.
    var headingLevel: Int?
    /// Where a link goes.
    var url: URL?
    /// Whether this is a code block, for the Code Blocks rotor.
    var isCode = false
    /// A code block's name, "Swift code, 3 lines": the start of its value
    /// and the Code Blocks rotor's entry.
    var codeName: String?
    /// Actions of this element's own, before the message's.
    var ownActions: [NSAccessibilityCustomAction] = []
    /// A list's items, a table's rows, and links inside either.
    var items: [ReplyElement] = []

    init(row: MessageRowView, parent: AnyObject, role: NSAccessibility.Role, range: NSRange, shape: Shape) {
        self.row = row
        self.parentElement = parent
        self.role = role
        self.range = range
        self.shape = shape
        super.init()
    }

    /// What SwiftUI's `.isHeader` trait publishes on macOS, measured from a
    /// hosted SwiftUI heading: role AXHeading, role description "heading",
    /// its words as the label, and its level under AXHeadingLevel. AppKit
    /// has no constant for the role.
    static let headingRole = NSAccessibility.Role(rawValue: "AXHeading")
    static let headingRoleDescription = "heading"
    static let headingLevelAttribute = "AXHeadingLevel"

    /// Rotors take their targets as NSAccessibilityElementProtocol, which
    /// asks for an identifier that is never nil.
    override func accessibilityIdentifier() -> String { "reply.\(role.rawValue)" }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { role }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { subrole }
    override func accessibilityRoleDescription() -> String? {
        roleDescription ?? role.description(with: subrole)
    }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { value }
    override func accessibilityChildren() -> [Any]? { items.isEmpty ? nil : items }
    override func accessibilityParent() -> Any? { parentElement }
    override func accessibilityWindow() -> Any? { onMain { $0.window } }
    override func accessibilityTopLevelUIElement() -> Any? { onMain { $0.window } }

    override func accessibilityFrame() -> NSRect {
        let range = range, shape = shape
        return onMain { $0.accessibilityFrame(ofText: range, shape: shape) } ?? .zero
    }

    /// The element's own actions, then the message's (Copy message, Mark
    /// message), so a reader inside the reply needn't leave it to mark it.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let actions = ownActions + (onMain { $0.messageActions } ?? [])
        return actions.isEmpty ? nil : actions
    }

    /// AXScrollToVisible, which VoiceOver sends before landing on a hot spot.
    /// The protocol has no method for it, and NSAccessibilityElement answers
    /// every action it doesn't know with success: the block said it had
    /// scrolled, VoiceOver believed it, and a hot spot on text that had
    /// scrolled away landed off screen with nothing read.
    static let scrollToVisibleAction = NSAccessibility.Action(rawValue: "AXScrollToVisible")

    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        guard action == Self.scrollToVisibleAction else { return super.accessibilityPerformAction(action) }
        let range = range, shape = shape
        _ = onMain { $0.scrollTextToVisible(range, shape: shape) }
    }

    /// The deepest element at a point on screen, for VoiceOver's mouse and
    /// trackpad commanders.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        for item in items where item.accessibilityFrame().contains(point) {
            return item.accessibilityHitTest(point)
        }
        return self
    }

    // The heading level has no NSAccessibility property, so it's answered
    // through the attribute API, as AppKit does for attributes it lacks.
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        let names = super.accessibilityAttributeNames()
        guard headingLevel != nil else { return names }
        return names + [NSAccessibility.Attribute(rawValue: Self.headingLevelAttribute)]
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        if attribute.rawValue == Self.headingLevelAttribute { return headingLevel }
        return super.accessibilityAttributeValue(attribute)
    }

    /// Runs `body` with the row; AppKit asks for accessibility on the main
    /// thread, so this is already there.
    func onMain<T>(_ body: @MainActor (MessageRowView) -> T) -> T? {
        nonisolated(unsafe) let row = row
        nonisolated(unsafe) var result: T?
        MainActor.assumeIsolated {
            if let row { result = body(row) }
        }
        return result
    }
}

/// A reply's elements, kept by block identity. While a reply streams, its
/// blocks keep their ids, so each keeps its element and VoiceOver's cursor
/// stays put; only a changed block's words are updated, and the children
/// list is only replaced when blocks come or go.
@MainActor
final class ReplyAccessibilityTree {
    private struct Kept {
        let element: ReplyElement
        /// Links after the block, at the reply's level.
        var links: [ReplyElement]
        var revision: BlockRevision
        var range: NSRange
        var isFinished: Bool
    }

    private var kept: [BlockID: Kept] = [:]
    /// The reply's elements in reading order.
    private(set) var children: [ReplyElement] = []

    /// Brings the elements up to date with the reply as last drawn.
    /// Returns whether the list of children changed.
    @discardableResult
    func update(
        blocks: [StreamingMarkdown.DrawnBlock], text: NSAttributedString, isFinished: Bool, row: MessageRowView
    ) -> Bool {
        var output: [ReplyElement] = []
        var seen: Set<BlockID> = []
        for block in blocks {
            if case .thematicBreak = block.content { continue }
            guard NSMaxRange(block.range) <= text.length else { continue }
            seen.insert(block.id)
            var entry: Kept
            if let old = kept[block.id], Self.role(for: block.content) == old.element.role {
                entry = old
                if old.revision != block.revision || old.range != block.range || old.isFinished != isFinished {
                    entry.links = describe(entry.element, block: block, text: text, isFinished: isFinished, row: row, links: old.links)
                }
            } else {
                let element = ReplyElement(
                    row: row, parent: row, role: Self.role(for: block.content), range: block.range, shape: .lines
                )
                let links = describe(element, block: block, text: text, isFinished: isFinished, row: row, links: [])
                entry = Kept(element: element, links: links, revision: block.revision, range: block.range, isFinished: isFinished)
            }
            entry.revision = block.revision
            entry.range = block.range
            entry.isFinished = isFinished
            kept[block.id] = entry
            output.append(entry.element)
            output.append(contentsOf: entry.links)
        }
        kept = kept.filter { seen.contains($0.key) }
        // Replacing the children makes VoiceOver fetch them again; while a
        // reply streams into its last block they're the same elements.
        guard output.count != children.count || !zip(output, children).allSatisfy({ $0 === $1 }) else { return false }
        children = output
        return true
    }

    /// Forgets every element, for a reply whose text was replaced.
    func reset() {
        kept = [:]
        children = []
    }

    private static func role(for content: BlockContent) -> NSAccessibility.Role {
        switch content {
        case .heading: ReplyElement.headingRole
        case .unorderedList, .orderedList: .list
        case .table: .group
        default: .staticText
        }
    }

    /// Sets an element's words, items and own actions from its block, and
    /// returns the links that follow it. Items and links are reused by
    /// position, so a list growing an item keeps the earlier items.
    private func describe(
        _ element: ReplyElement, block: StreamingMarkdown.DrawnBlock, text: NSAttributedString,
        isFinished: Bool, row: MessageRowView, links oldLinks: [ReplyElement]
    ) -> [ReplyElement] {
        let range = block.range
        let plain = (text.string as NSString).substring(with: range)
        element.range = range
        element.shape = .lines
        element.label = nil
        element.value = nil
        element.subrole = nil
        element.roleDescription = nil
        element.headingLevel = nil
        element.isCode = false
        element.codeName = nil
        element.ownActions = []
        var linksAfter = true
        var newItems: [ReplyElement] = []
        switch block.content {
        case .heading(let level, _):
            element.label = ReplyBlockWording.singleLine(plain)
            element.headingLevel = level
            element.roleDescription = ReplyElement.headingRoleDescription
        case .codeBlock(let code):
            let body = plain.trimmingCharacters(in: .newlines)
            element.isCode = true
            element.shape = .card
            // The name leads the value rather than being the label:
            // VoiceOver speaks a static text's value before its label, so
            // as a label "Swift code, 3 lines" came after all the code.
            let name = ReplyBlockWording.codeLabel(
                fenceInfo: code.languageHint, code: body, isReceiving: !code.isClosed && !isFinished
            )
            element.label = nil
            element.codeName = name
            element.value = "\(name): \(body)"
            element.ownActions = [NSAccessibilityCustomAction(name: "Copy code") {
                Clipboard.copy(body)
                Announcer.announce("Copied.")
                return true
            }]
            linksAfter = false
        case .unorderedList(let items):
            element.subrole = .contentList
            newItems = listItems(items, start: nil, in: block, text: text, row: row, parent: element, old: element.items)
            linksAfter = false
        case .orderedList(let start, let items):
            element.subrole = .contentList
            newItems = listItems(items, start: start, in: block, text: text, row: row, parent: element, old: element.items)
            linksAfter = false
        case .table(let table):
            let rows = [table.head] + table.rows
            element.label = ReplyBlockWording.tableLabel(rows: rows.count)
            newItems = tableRows(rows, in: block, text: text, row: row, parent: element, old: element.items)
            linksAfter = false
        case .blockQuote:
            element.label = "Quote"
            element.value = Self.readable(plain)
        case .paragraph, .htmlBlock, .thematicBreak:
            element.value = Self.readable(plain)
        }
        element.items = newItems
        return linksAfter ? links(in: range, text: text, row: row, parent: row, old: oldLinks) : []
    }

    /// Text as read: no leading or trailing blank lines.
    private static func readable(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One element per list item, each followed by the links inside it.
    private func listItems(
        _ items: [[BlockContent]], start: Int?, in block: StreamingMarkdown.DrawnBlock, text: NSAttributedString,
        row: MessageRowView, parent: ReplyElement, old: [ReplyElement]
    ) -> [ReplyElement] {
        let ranges = Self.itemRanges(items, start: start, in: block.range, text: text)
        let source = text.string as NSString
        var output: [ReplyElement] = []
        var oldItems = old.filter { $0.role == .staticText }
        var oldLinks = old.filter { $0.role == .link }
        for (index, range) in ranges.enumerated() {
            let item = oldItems.isEmpty
                ? ReplyElement(row: row, parent: parent, role: .staticText, range: range, shape: .lines)
                : oldItems.removeFirst()
            item.range = range
            let number = start.map { $0 + index }
            item.value = ReplyBlockWording.listItem(Self.itemText(source.substring(with: range)), number: number)
            output.append(item)
            let links = links(in: range, text: text, row: row, parent: parent, old: oldLinks)
            oldLinks.removeFirst(min(links.count, oldLinks.count))
            output.append(contentsOf: links)
        }
        return output
    }

    /// Each item's characters in the rendered list. The renderer writes an
    /// item as its marker then its blocks, items joined by newlines; an item
    /// rendered alone has the same length. When that doesn't add up to the
    /// list (a renderer change), each line is taken as an item.
    static func itemRanges(_ items: [[BlockContent]], start: Int?, in range: NSRange, text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = range.location
        for (index, item) in items.enumerated() {
            if index > 0 { location += 1 }
            let marker = start.map { "\($0 + index).  " } ?? "•  "
            let length = (marker as NSString).length + AppKitMarkdownRenderer.attributedString(for: item).length
            ranges.append(NSRange(location: location, length: length))
            location += length
        }
        if location == NSMaxRange(range) { return ranges }
        return lineRanges(in: range, text: text)
    }

    /// The non-empty lines of `range`.
    static func lineRanges(in range: NSRange, text: NSAttributedString) -> [NSRange] {
        let source = text.string as NSString
        var ranges: [NSRange] = []
        source.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            if line.length > 0 { ranges.append(line) }
        }
        return ranges
    }

    /// An item's words without its marker or the markers of lists inside it.
    static func itemText(_ rendered: String) -> String {
        let lines = rendered.split(whereSeparator: \.isNewline).map { line in
            var words = line.drop(while: \.isWhitespace)
            if words.first == "•" {
                words = words.dropFirst()
            } else {
                let digits = words.prefix(while: \.isNumber)
                if !digits.isEmpty, words.dropFirst(digits.count).first == "." { words = words.dropFirst(digits.count + 1) }
            }
            return String(words)
        }
        return ReplyBlockWording.singleLine(lines.joined(separator: " "))
    }

    /// One element per table row, header first, each its own line.
    private func tableRows(
        _ rows: [[InlineText]], in block: StreamingMarkdown.DrawnBlock, text: NSAttributedString,
        row: MessageRowView, parent: ReplyElement, old: [ReplyElement]
    ) -> [ReplyElement] {
        var ranges: [Int: NSRange] = [:]
        text.enumerateAttribute(ReplyTable.rowAttribute, in: block.range) { value, range, _ in
            guard let index = value as? Int else { return }
            ranges[index] = ranges[index].map { NSUnionRange($0, range) } ?? range
        }
        var output: [ReplyElement] = []
        var oldRows = old.filter { $0.role == .staticText }
        var oldLinks = old.filter { $0.role == .link }
        for (index, cells) in rows.enumerated() {
            let range = ranges[index] ?? block.range
            let element = oldRows.isEmpty
                ? ReplyElement(row: row, parent: parent, role: .staticText, range: range, shape: .lines)
                : oldRows.removeFirst()
            element.range = range
            element.value = ReplyBlockWording.tableRow(index + 1, cells: cells.map { ReplyBlockWording.singleLine($0.plainText) })
            output.append(element)
            let rowLinks = links(in: range, text: text, row: row, parent: parent, old: oldLinks)
            oldLinks.removeFirst(min(rowLinks.count, oldLinks.count))
            output.append(contentsOf: rowLinks)
        }
        return output
    }

    /// A link element for each web or mail link in `range`, in order.
    private func links(
        in range: NSRange, text: NSAttributedString, row: MessageRowView, parent: AnyObject, old: [ReplyElement]
    ) -> [ReplyElement] {
        var output: [ReplyElement] = []
        text.enumerateAttribute(.link, in: range) { value, linkRange, _ in
            guard let url = MessageRowView.openableURL(value) else { return }
            let element = output.count < old.count
                ? old[output.count]
                : ReplyLinkElement(row: row, parent: parent, role: .link, range: linkRange, shape: .glyphs)
            element.parentElement = parent
            element.range = linkRange
            element.url = url
            element.label = MessageRowView.linkTitle(url: url, text: (text.string as NSString).substring(with: linkRange))
            output.append(element)
        }
        return output
    }
}

/// A web or mail link in a reply. Pressing it (VO-Space) opens it; only
/// links answer a press, so no other block offers one.
final class ReplyLinkElement: ReplyElement, @unchecked Sendable {
    override func accessibilityPerformPress() -> Bool {
        guard let url else { return false }
        return onMain { _ in NSWorkspace.shared.open(url) } ?? false
    }
}
