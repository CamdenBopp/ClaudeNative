import CoreGraphics
import CoreText
import Foundation
import ChatMarkdownCore

// MARK: - Result model

public enum BlockAccessibilityRole: Hashable, Sendable {
    case paragraph
    case heading(level: Int)
    case quote
    case list
    case table
    case code
    case rule
    case html
}

/// Accessibility projection of one block, produced by the same layout pass
/// that produces the draw commands — never a second parse.
public struct BlockAccessibility: Hashable, Sendable {
    public let label: String
    public let role: BlockAccessibilityRole
}

/// One link's geometry within a block (block-local, top-left origin).
/// Consecutive runs with the same destination merge into one region.
public struct LinkRegion: Equatable, Sendable {
    public let destination: String
    /// The visible link text — what VoiceOver speaks; the destination goes
    /// in the hint so "example.com slash docs" isn't the label.
    public let text: String
    public let rects: [CGRect]
}

/// One list item's geometry and speech within a top-level list block
/// (block-local, top-left origin), so VoiceOver can swipe through items one
/// at a time instead of hearing the whole list as a single run-on sentence.
public struct ListItemRegion: Equatable, Sendable {
    public let label: String
    public let frame: CGRect
}

/// Everything a block draws, in block-local top-left coordinates. Colors are
/// resolved at draw time from a palette so appearance changes never touch
/// cached geometry.
public enum DrawCommand: Sendable {
    case text(TextLayoutResult, at: CGPoint)
    case rule(CGRect)
    case quoteBar(CGRect)
}

/// Draw-time colors, resolved from the current trait collection at render
/// *request* time — never cached with geometry. `@unchecked Sendable`:
/// CGColor is an immutable CoreFoundation object, safe to hand to the
/// background bitmap renderer.
public struct DrawPalette: @unchecked Sendable {
    public var text: CGColor
    public var rule: CGColor
    public var quoteBar: CGColor
    /// Fill color for link runs. Defaults to `text` when not supplied so
    /// existing three-color call sites keep their old behavior.
    public var link: CGColor

    public init(text: CGColor, rule: CGColor, quoteBar: CGColor, link: CGColor? = nil) {
        self.text = text
        self.rule = rule
        self.quoteBar = quoteBar
        self.link = link ?? text
    }
}

/// Immutable result of laying out one block at one width in one environment —
/// the value that the layout cache stores and the main thread draws.
public struct BlockLayoutResult: Sendable {
    public let blockID: BlockID
    public let blockRevision: BlockRevision
    public let size: CGSize
    public let commands: [DrawCommand]
    public let links: [LinkRegion]
    public let accessibility: BlockAccessibility
    /// Per-item VoiceOver elements for a top-level list block, flattened to
    /// include items from lists nested inside a list item (each still its own
    /// swipe stop, in reading order after its parent item); empty for every
    /// other block kind, including a list nested inside a quote, which still
    /// speaks as one folded element.
    public let listItems: [ListItemRegion]

    /// Approximate resident bytes, for cache cost accounting.
    public var estimatedCost: Int {
        var cost = 256
        for command in commands {
            if case .text(let result, _) = command {
                cost += 96 * max(1, result.lines.count)
            } else {
                cost += 32
            }
        }
        cost += links.count * 64
        return cost
    }

    public func draw(in context: CGContext, palette: DrawPalette) {
        for command in commands {
            switch command {
            case .text(let result, let origin):
                context.saveGState()
                context.translateBy(x: origin.x, y: origin.y)
                result.draw(in: context, textColor: palette.text, linkColor: palette.link)
                context.restoreGState()
            case .rule(let rect):
                context.setFillColor(palette.rule)
                context.fill(rect)
            case .quoteBar(let rect):
                context.setFillColor(palette.quoteBar)
                context.fill(rect)
            }
        }
    }
}

// MARK: - Engine

/// Pure block-content → layout function. The scheduler owns threading,
/// cancellation, and caching above this level.
public enum BlockLayoutEngine {
    public static func layout(
        block: MarkdownBlock,
        width: CGFloat,
        theme: TextTheme,
        environment: RenderEnvironment
    ) -> BlockLayoutResult {
        let inner = layoutContent(block.content, width: width, theme: theme, environment: environment)
        return BlockLayoutResult(
            blockID: block.id,
            blockRevision: block.revision,
            size: inner.size,
            commands: inner.commands,
            links: inner.links,
            accessibility: BlockAccessibility(label: inner.spokenText, role: inner.role),
            listItems: inner.listItems
        )
    }

    struct InnerLayout {
        var size: CGSize
        var commands: [DrawCommand]
        var links: [LinkRegion]
        var spokenText: String
        var role: BlockAccessibilityRole
        var listItems: [ListItemRegion] = []

        /// Approximate resident bytes, for child-cache cost accounting.
        var estimatedCost: Int {
            var cost = 256 + spokenText.utf8.count
            for command in commands {
                if case .text(let result, _) = command {
                    cost += 96 * max(1, result.lines.count)
                } else {
                    cost += 32
                }
            }
            cost += links.count * 64 + listItems.count * 64
            return cost
        }
    }

    /// Cache for *child* layouts inside composite blocks (list items, quote
    /// children, list markers). During streaming, the tail list/quote block is
    /// re-laid-out on every token, but only its last child is actually
    /// changing — without this cache a growing list is O(items²) layout work
    /// over its stream life. Top-level blocks are NOT cached here (the
    /// scheduler already caches those by revision).
    ///
    /// Lock-protected shared state, unlike the owner-confined LRU instances
    /// elsewhere: `BlockLayoutEngine` is a stateless enum invoked from
    /// whichever context the scheduler (or a test) runs layout on, so there
    /// is no single owner to confine to. Values are immutable structs whose
    /// CTLines are already shared across threads by design.
    private final class ChildLayoutCache: @unchecked Sendable {
        static let shared = ChildLayoutCache()

        struct Key: Hashable {
            let content: BlockContent
            let width: CGFloat
            let theme: TextTheme
            let environment: RenderEnvironment
        }

        private let lock = NSLock()
        private var cache = LRUCache<Key, InnerLayout>(costLimit: 1_000_000)

        func layout(
            _ content: BlockContent,
            width: CGFloat,
            theme: TextTheme,
            environment: RenderEnvironment
        ) -> InnerLayout {
            let key = Key(content: content, width: width, theme: theme, environment: environment)
            lock.lock()
            if let cached = cache.value(for: key) {
                lock.unlock()
                return cached
            }
            lock.unlock()
            // Lay out outside the lock; a racing duplicate is equivalent.
            let layout = BlockLayoutEngine.layoutContent(
                content, width: width, theme: theme, environment: environment
            )
            lock.lock()
            cache.insert(layout, for: key, cost: layout.estimatedCost)
            lock.unlock()
            return layout
        }
    }

    static func layoutContent(
        _ content: BlockContent,
        width: CGFloat,
        theme: TextTheme,
        environment: RenderEnvironment
    ) -> InnerLayout {
        switch content {
        case .paragraph(let text):
            return textLayout(
                text, role: .paragraph, spoken: text.plainText,
                width: width, theme: theme
            )
        case .heading(let level, let text):
            return textLayout(
                text, role: .heading(level: level), spoken: text.plainText,
                width: width, theme: theme,
                roleAttributes: .bold, sizeMultiplier: theme.headingScale(for: level)
            )
        case .codeBlock(let code):
            // Top-level code blocks are owned by the code subsystem
            // (ChatCodeBlocks) and are skipped by the scheduler. This path
            // serves code blocks *nested* inside quotes/lists, which are
            // typically small: plain monospaced text.
            let text = InlineText(runs: [InlineRun(text: code.rawText, attributes: .code)])
            return textLayout(
                text, role: .code, spoken: "Code: " + code.rawText,
                width: width, theme: theme
            )
        case .blockQuote(let children):
            return quoteLayout(children, width: width, theme: theme, environment: environment)
        case .unorderedList(let items):
            return listLayout(items, ordered: false, start: 1, width: width, theme: theme, environment: environment)
        case .orderedList(let start, let items):
            return listLayout(items, ordered: true, start: start, width: width, theme: theme, environment: environment)
        case .table(let table):
            return tableLayout(table, width: width, theme: theme, environment: environment)
        case .thematicBreak:
            let height = theme.thematicBreakHeight
            let rect = CGRect(x: 0, y: (height - 1) / 2, width: width, height: 1)
            return InnerLayout(
                size: CGSize(width: width, height: height),
                commands: [.rule(rect)], links: [],
                spokenText: "Divider", role: .rule
            )
        case .htmlBlock(let literal):
            // Literal, monospaced, never interpreted.
            let text = InlineText(runs: [InlineRun(text: literal, attributes: .code)])
            return textLayout(text, role: .html, spoken: literal, width: width, theme: theme)
        }
    }

    // MARK: Leaf text

    private static func textLayout(
        _ text: InlineText,
        role: BlockAccessibilityRole,
        spoken: String,
        width: CGFloat,
        theme: TextTheme,
        roleAttributes: InlineRun.Attributes = [],
        sizeMultiplier: CGFloat = 1
    ) -> InnerLayout {
        let attributed = AttributedTextBuilder.makeAttributedString(
            text, theme: theme, roleAttributes: roleAttributes, sizeMultiplier: sizeMultiplier
        )
        let result = TextLayoutEngine.layout(attributedString: attributed, width: width)
        return InnerLayout(
            size: result.size,
            commands: [.text(result, at: .zero)],
            links: LinkRegionExtractor.regions(in: result, attributed: attributed),
            spokenText: spoken,
            role: role
        )
    }

    // MARK: Quote

    private static func quoteLayout(
        _ children: [BlockContent],
        width: CGFloat,
        theme: TextTheme,
        environment: RenderEnvironment
    ) -> InnerLayout {
        let innerWidth = max(theme.minimumContentWidth, width - theme.quoteIndent)
        var commands: [DrawCommand] = []
        var links: [LinkRegion] = []
        var spokenParts: [String] = []
        var y: CGFloat = 0

        for (index, child) in children.enumerated() {
            if index > 0 { y += theme.innerBlockSpacing }
            let child = ChildLayoutCache.shared.layout(child, width: innerWidth, theme: theme, environment: environment)
            let offset = CGPoint(x: theme.quoteIndent, y: y)
            commands.append(contentsOf: offsetCommands(child.commands, by: offset))
            links.append(contentsOf: offsetLinks(child.links, by: offset))
            spokenParts.append(child.spokenText)
            y += child.size.height
        }

        let height = max(y, theme.quoteBarWidth)
        commands.insert(.quoteBar(CGRect(x: 0, y: 0, width: theme.quoteBarWidth, height: height)), at: 0)
        return InnerLayout(
            size: CGSize(width: width, height: height),
            commands: commands,
            links: links,
            spokenText: "Quote: " + spokenParts.joined(separator: " "),
            role: .quote
        )
    }

    // MARK: Lists

    private static func listLayout(
        _ items: [[BlockContent]],
        ordered: Bool,
        start: Int,
        width: CGFloat,
        theme: TextTheme,
        environment: RenderEnvironment
    ) -> InnerLayout {
        let contentX = theme.listIndent
        let innerWidth = max(theme.minimumContentWidth, width - contentX)
        var commands: [DrawCommand] = []
        var links: [LinkRegion] = []
        var spokenItems: [String] = []
        var listItems: [ListItemRegion] = []
        var y: CGFloat = 0

        for (itemIndex, item) in items.enumerated() {
            let itemTop = itemIndex > 0 ? y + theme.listItemSpacing : y
            y = itemTop
            let markerString = ordered ? "\(start + itemIndex)." : "•"
            // Markers ride the child cache as tiny paragraphs; the key space
            // is small ("•", "1.", "2.", …) and hit on every list relayout.
            let markerLayout = ChildLayoutCache.shared.layout(
                .paragraph(.plain(markerString)), width: contentX, theme: theme, environment: environment
            )
            guard case .some(.text(let marker, _)) = markerLayout.commands.first else {
                continue
            }
            let markerX = max(0, contentX - theme.listMarkerGap - marker.size.width)
            commands.append(.text(marker, at: CGPoint(x: markerX, y: y)))

            var innerY = y
            var itemSpoken: [String] = []
            // A nested list inside this item (e.g. a sub-bullet under a
            // top-level bullet) gets its own items flattened in here rather
            // than folded into this item's spoken label as a "List with N
            // items" run-on — each nested bullet becomes its own swipe stop,
            // same as a top-level list already does. Collected separately and
            // appended after this item's own region below, so reading order
            // stays parent-then-children instead of children-then-parent.
            var nestedListItems: [ListItemRegion] = []
            for (childIndex, child) in item.enumerated() {
                if childIndex > 0 { innerY += theme.innerBlockSpacing }
                let childLayout = ChildLayoutCache.shared.layout(child, width: innerWidth, theme: theme, environment: environment)
                let offset = CGPoint(x: contentX, y: innerY)
                commands.append(contentsOf: offsetCommands(childLayout.commands, by: offset))
                links.append(contentsOf: offsetLinks(childLayout.links, by: offset))
                if childLayout.listItems.isEmpty {
                    itemSpoken.append(childLayout.spokenText)
                } else {
                    nestedListItems.append(contentsOf: childLayout.listItems.map {
                        ListItemRegion(label: $0.label, frame: $0.frame.offsetBy(dx: offset.x, dy: offset.y))
                    })
                }
                innerY += childLayout.size.height
            }
            let itemHeight = max(innerY - itemTop, marker.size.height)
            y = itemTop + itemHeight
            let spokenItem = itemSpoken.joined(separator: " ")
            spokenItems.append(spokenItem)
            let label = spokenItem.isEmpty
                ? "Item \(itemIndex + 1) of \(items.count)"
                : "Item \(itemIndex + 1) of \(items.count): \(spokenItem)"
            listItems.append(ListItemRegion(
                label: label,
                frame: CGRect(x: 0, y: itemTop, width: width, height: itemHeight)
            ))
            listItems.append(contentsOf: nestedListItems)
        }

        // Folded summary kept for lists nested inside a quote (which still
        // speak as one element); top-level lists are projected per-item
        // instead (`AccessibilityProjector`), so VoiceOver can swipe through
        // each bullet rather than hearing "list, N items" as one run-on.
        let spoken = "List with \(items.count) item\(items.count == 1 ? "" : "s"): "
            + spokenItems.joined(separator: "; ")
        return InnerLayout(
            size: CGSize(width: width, height: y),
            commands: commands,
            links: links,
            spokenText: spoken,
            role: .list,
            listItems: listItems
        )
    }

    // MARK: Tables

    private static func tableLayout(
        _ table: TableContent,
        width: CGFloat,
        theme: TextTheme,
        environment: RenderEnvironment
    ) -> InnerLayout {
        let columnCount = max(table.head.count, table.rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else {
            return InnerLayout(size: .zero, commands: [], links: [], spokenText: "Empty table", role: .table)
        }
        let hairline = 1 / max(1, environment.displayScale)
        let padding = theme.tableCellPadding

        // Column widths are the natural (unwrapped) width of each column — cells
        // never wrap and never shrink to fit the bubble. A table wider than the
        // message overflows its natural width; the host (`TableBlockView`)
        // scrolls it horizontally rather than squishing columns (which would
        // clip multi-word cells that cannot word-break in a pinned-narrow
        // column). Layout is therefore viewport-independent — `width` is unused.
        //
        // Single layout pass: each cell is laid out once at effectively
        // unbounded width and that SAME layout is placed below. Correct
        // because a column is always at least as wide as each of its cells'
        // natural width, so a second layout at the final column width could
        // never break lines differently — it used to be done anyway, doubling
        // every table's CoreText work on every streamed token.
        //
        // Cells ride the child cache as paragraphs (header boldness folded
        // into the run attributes so the key captures it): a streaming table
        // block re-lays-out on every token, but only the growing cell's
        // content is actually new — every settled cell is a cache hit, links
        // included.
        func naturalLayout(_ cell: InlineText, bold: Bool) -> InnerLayout {
            var styled = cell
            if bold {
                styled = InlineText(runs: cell.runs.map { run in
                    var run = run
                    run.attributes.insert(.bold)
                    return run
                })
            }
            return ChildLayoutCache.shared.layout(
                .paragraph(styled), width: 100_000, theme: theme, environment: environment
            )
        }
        let headLayouts = table.head.map { naturalLayout($0, bold: true) }
        let rowLayouts = table.rows.map { row in row.map { naturalLayout($0, bold: false) } }

        var columnWidths = [CGFloat](repeating: theme.tableMinColumnWidth, count: columnCount)
        for (column, cell) in headLayouts.enumerated() {
            columnWidths[column] = max(columnWidths[column], cell.size.width)
        }
        for row in rowLayouts {
            for (column, cell) in row.enumerated() where column < columnCount {
                columnWidths[column] = max(columnWidths[column], cell.size.width)
            }
        }
        let chrome = CGFloat(columnCount) * 2 * padding + CGFloat(columnCount + 1) * hairline
        let tableWidth = columnWidths.reduce(0, +) + chrome

        // Placement pass: no further text layout.
        var commands: [DrawCommand] = []
        var links: [LinkRegion] = []
        var y: CGFloat = 0

        func placeRow(_ cells: [InnerLayout]) -> CGFloat {
            var x = hairline
            var rowHeight: CGFloat = 0
            for column in 0..<columnCount {
                defer { x += columnWidths[column] + 2 * padding + hairline }
                // Missing trailing cells draw nothing (an empty layout has no
                // lines and zero height, exactly as before).
                guard column < cells.count else { continue }
                let cell = cells[column]
                let origin = CGPoint(x: x + padding, y: y + padding)
                commands.append(contentsOf: offsetCommands(cell.commands, by: origin))
                links.append(contentsOf: offsetLinks(cell.links, by: origin))
                rowHeight = max(rowHeight, cell.size.height)
            }
            return rowHeight + 2 * padding
        }

        commands.append(.rule(CGRect(x: 0, y: 0, width: tableWidth, height: hairline)))
        y += hairline
        if !table.head.isEmpty {
            y += placeRow(headLayouts)
            commands.append(.rule(CGRect(x: 0, y: y, width: tableWidth, height: hairline)))
            y += hairline
        }
        for row in rowLayouts {
            y += placeRow(row)
            commands.append(.rule(CGRect(x: 0, y: y, width: tableWidth, height: hairline)))
            y += hairline
        }
        // Column separators (including outer edges).
        var separatorX: CGFloat = 0
        commands.append(.rule(CGRect(x: 0, y: 0, width: hairline, height: y)))
        for columnWidth in columnWidths {
            separatorX += hairline + 2 * padding + columnWidth
            commands.append(.rule(CGRect(x: separatorX, y: 0, width: hairline, height: y)))
        }

        var spoken = "Table with \(columnCount) columns and \(table.rows.count) rows."
        if !table.head.isEmpty {
            spoken += " Columns: " + table.head.map(\.plainText).joined(separator: ", ") + "."
        }
        for (index, row) in table.rows.enumerated() {
            spoken += " Row \(index + 1): " + row.map(\.plainText).joined(separator: ", ") + "."
        }
        return InnerLayout(
            size: CGSize(width: tableWidth, height: y),
            commands: commands,
            links: links,
            spokenText: spoken,
            role: .table
        )
    }

    // MARK: Offsets

    private static func offsetCommands(_ commands: [DrawCommand], by delta: CGPoint) -> [DrawCommand] {
        commands.map { command in
            switch command {
            case .text(let result, let origin):
                return .text(result, at: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y))
            case .rule(let rect):
                return .rule(rect.offsetBy(dx: delta.x, dy: delta.y))
            case .quoteBar(let rect):
                return .quoteBar(rect.offsetBy(dx: delta.x, dy: delta.y))
            }
        }
    }

    private static func offsetLinks(_ links: [LinkRegion], by delta: CGPoint) -> [LinkRegion] {
        links.map { link in
            LinkRegion(
                destination: link.destination,
                text: link.text,
                rects: link.rects.map { $0.offsetBy(dx: delta.x, dy: delta.y) }
            )
        }
    }
}

// MARK: - Link extraction

/// Reads link geometry (and the visible link text) back out of laid-out
/// lines. Run attributes survive inside CTLine; the attributed string is only
/// needed to slice the text for each run's string range.
enum LinkRegionExtractor {
    static func regions(in layout: TextLayoutResult, attributed: NSAttributedString) -> [LinkRegion] {
        var regions: [LinkRegion] = []
        var currentDestination: String?
        var currentText = ""
        var currentRects: [CGRect] = []
        let string = attributed.string as NSString

        func flush() {
            if let destination = currentDestination, !currentRects.isEmpty {
                regions.append(LinkRegion(destination: destination, text: currentText, rects: currentRects))
            }
            currentDestination = nil
            currentText = ""
            currentRects = []
        }

        let height = layout.size.height
        for snapshot in layout.lines {
            let runs = (CTLineGetGlyphRuns(snapshot.line) as? [CTRun]) ?? []
            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let destination = attributes[CMKAttribute.linkDestination.rawValue] as? String,
                      CTRunGetGlyphCount(run) > 0
                else {
                    flush()
                    continue
                }
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let runWidth = CGFloat(CTRunGetTypographicBounds(
                    run, CFRange(location: 0, length: 0), &ascent, &descent, &leading
                ))
                let stringRange = CTRunGetStringRange(run)
                // First glyph's pen position, not CTLineGetOffsetForStringIndex:
                // the positions are already computed by the typesetter, while
                // GetOffsetForStringIndex re-walks the line's glyph clusters —
                // a profile showed it dominating link extraction, which runs on
                // every re-layout of a streaming link-bearing paragraph.
                var xOffset: CGFloat = 0
                if let positions = CTRunGetPositionsPtr(run) {
                    xOffset = positions[0].x
                } else {
                    var position = CGPoint.zero
                    CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                    xOffset = position.x
                }
                let rect = CGRect(
                    x: snapshot.origin.x + xOffset,
                    y: height - snapshot.origin.y - ascent,
                    width: runWidth,
                    height: ascent + descent
                )
                let runText = string.substring(
                    with: NSRange(location: stringRange.location, length: stringRange.length)
                )
                if destination == currentDestination {
                    currentRects.append(rect)
                    currentText += runText
                } else {
                    flush()
                    currentDestination = destination
                    currentText = runText
                    currentRects = [rect]
                }
            }
        }
        flush()
        return regions
    }
}
