import AppKit
import ChatMarkdownAppKit
import ChatMarkdownCore
import ClaudeNativeCore
import SwiftUI

/// Turns a growing Markdown string into attributed text, feeding only the
/// new tail to ChatMarkdownKit's streaming parser.
@MainActor
final class StreamingMarkdown {
    private var assembler: StreamingMessageAssembler?
    /// Claude's single newlines are line breaks, as on claude.ai.
    private var lineBreaks = ChatLineBreaks.Stream()
    /// The reply as far as it has been parsed, in a buffer of its own: one
    /// shared with the transcript's entry would make each append there copy
    /// the whole reply.
    private var parsed = ""
    private(set) var isFinished = false
    /// The point size of the reply's body text.
    var bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize

    /// Only the text added since the last render is hardened and parsed, so
    /// a delta costs about its own length here, however long the reply.
    func render(_ reply: String) -> NSAttributedString {
        let delta: DocumentDelta
        if let assembler, let added = Self.continuation(of: parsed, in: reply) {
            delta = assembler.append(lineBreaks.append(added))
            parsed += added
        } else {
            // The text was replaced rather than extended: parse it afresh.
            let assembler = StreamingMessageAssembler(messageID: MessageID(UUID().uuidString))
            lineBreaks = ChatLineBreaks.Stream()
            delta = assembler.append(lineBreaks.append(reply))
            self.assembler = assembler
            parsed = ""
            parsed.reserveCapacity(reply.utf8.count)
            parsed += reply
        }
        isFinished = false
        return draw(delta.document)
    }

    /// What `reply` adds after `prefix`, or nil when it does not start with
    /// it. Compares bytes, which for a long reply is far cheaper than
    /// comparing Characters.
    private static func continuation(of prefix: String, in reply: String) -> String? {
        let count = prefix.utf8.count
        guard reply.utf8.count >= count else { return nil }
        let matches = reply.utf8.withContiguousStorageIfAvailable { replyBytes in
            prefix.utf8.withContiguousStorageIfAvailable { prefixBytes in
                guard count > 0 else { return true }
                guard let a = replyBytes.baseAddress, let b = prefixBytes.baseAddress else { return false }
                return memcmp(a, b, count) == 0
            }
        } ?? nil
        guard matches ?? reply.utf8.starts(with: prefix.utf8) else { return nil }
        return String(decoding: reply.utf8.dropFirst(count), as: UTF8.self)
    }

    /// The final full parse, once; nil when already finished or never started.
    func finish() -> NSAttributedString? {
        guard !isFinished, let assembler else { return nil }
        isFinished = true
        return draw(assembler.finish().document)
    }

    /// A block as last drawn. ChatMarkdownKit bumps a block's revision
    /// whenever its content changes, so the same id and revision draw the
    /// same text.
    struct DrawnBlock {
        let id: BlockID
        let revision: BlockRevision
        let content: BlockContent
        /// The block's characters in the rendered text, without the newline
        /// that joins it to the block before.
        let range: NSRange
        var end: Int { NSMaxRange(range) }
    }

    /// The reply's top-level blocks as last rendered, in order, each with
    /// where its text is.
    var blocks: [DrawnBlock] { drawnBlocks }

    private var drawnBlocks: [DrawnBlock] = []
    private let drawn = NSMutableAttributedString()
    private var drawnSize: CGFloat?
    /// How much of the text the last render left exactly as it was before.
    /// Anything laid out from that part alone is still right.
    private(set) var unchangedLength = 0

    /// Renders block by block, joined by newlines as ChatMarkdownKit does,
    /// so each code block's text can be colored by its fence language. Only
    /// the foreground changes; the code font and background stay.
    ///
    /// A streaming reply only changes at its end, so the blocks before the
    /// first changed one keep the text they were drawn with, and only the
    /// rest is drawn (and highlighted) again. Redrawing every block on every
    /// delta made a long reply quadratic.
    private func draw(_ document: MarkdownDocument) -> NSAttributedString {
        if drawnSize != bodySize {
            drawnSize = bodySize
            drawnBlocks = []
        }
        let blocks = document.blocks
        var kept = 0
        while kept < min(drawnBlocks.count, blocks.count),
              drawnBlocks[kept].id == blocks[kept].id,
              drawnBlocks[kept].revision == blocks[kept].revision {
            kept += 1
        }
        drawnBlocks.removeSubrange(kept...)
        let start = drawnBlocks.last?.end ?? 0
        let tail = NSMutableAttributedString()
        var style = MarkdownRenderStyle()
        style.bodySize = bodySize
        style.linkColor = Theme.linkText
        // List numbers, quotes and rules: the system secondary color is 50%
        // black in light, and list numbers measured 3.07:1 on screen.
        style.secondaryColor = Theme.quietLabel
        for (index, block) in blocks.enumerated().dropFirst(kept) {
            if index > 0 { tail.append(NSAttributedString(string: "\n")) }
            let blockStart = start + tail.length
            let piece: NSMutableAttributedString
            if case .table(let table) = block.content {
                piece = ReplyTable.render(table, style: style)
            } else {
                piece = NSMutableAttributedString(attributedString: AppKitMarkdownRenderer.attributedString(for: [block.content], style: style))
            }
            if case .codeBlock(let code) = block.content {
                Self.colorCode(piece, language: code.languageHint, fontSize: style.bodySize)
                Self.setOffCode(piece, caption: ReplyBlockWording.languageName(fenceInfo: code.languageHint), bodySize: style.bodySize)
            }
            tail.append(piece)
            drawnBlocks.append(DrawnBlock(
                id: block.id, revision: block.revision, content: block.content,
                range: NSRange(location: blockStart, length: start + tail.length - blockStart)
            ))
        }
        drawn.replaceCharacters(in: NSRange(location: start, length: drawn.length - start), with: tail)
        unchangedLength = start
        return NSAttributedString(attributedString: drawn)
    }

    /// The renderer shades code with a background behind the characters,
    /// which draws ragged boxes of different widths, one per line. One text
    /// block spanning the whole code block draws a single full-width card
    /// behind it instead, with padding around the text.
    private static func setOffCode(_ piece: NSMutableAttributedString, caption: String?, bodySize: CGFloat) {
        let whole = NSRange(location: 0, length: piece.length)
        piece.removeAttribute(.backgroundColor, range: whole)
        let card = CodeCardBlock(caption: caption, bodySize: bodySize)
        let text = piece.string as NSString
        // One paragraph per code line, so each can hang its wrapped part
        // under its own indentation.
        text.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, line, enclosing, _ in
            let value = piece.attribute(.paragraphStyle, at: enclosing.location, effectiveRange: nil)
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.textBlocks = [card]
            style.firstLineHeadIndent = 0
            style.headIndent = Self.wrapIndent(of: line, in: piece)
            piece.addAttribute(.paragraphStyle, value: style, range: enclosing)
        }
    }

    /// Where a wrapped code line continues: under the line's own leading
    /// whitespace plus one more indent, as Xcode wraps by default. Deep
    /// indentation is capped so a narrow column still has room for text.
    private static func wrapIndent(of line: NSRange, in piece: NSAttributedString) -> CGFloat {
        guard line.length > 0, let font = piece.attribute(.font, at: line.location, effectiveRange: nil) as? NSFont else { return 0 }
        let text = piece.string as NSString
        var leading = 0
        while leading < line.length, CharacterSet.whitespaces.contains(UnicodeScalar(text.character(at: line.location + leading)) ?? "x") {
            leading += 1
        }
        // Columns, with a tab drawn as four spaces; capped before measuring.
        let whitespace = text.substring(with: NSRange(location: line.location, length: leading))
        let columns = whitespace.reduce(0) { $0 + ($1 == "\t" ? CodeWrap.continuationSpaces : 1) }
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let indent = space * CGFloat(min(columns, CodeWrap.maxIndentCharacters) + CodeWrap.continuationSpaces)
        return min(indent, CodeWrap.maxIndentWidth)
    }

    private static func colorCode(_ piece: NSMutableAttributedString, language: String?, fontSize: CGFloat) {
        let highlighted = Highlighting.highlight(piece.string, language: language, fontSize: fontSize)
        guard highlighted.string == piece.string else { return }
        let whole = NSRange(location: 0, length: piece.length)
        highlighted.enumerateAttribute(.foregroundColor, in: whole) { color, range, _ in
            if let color { piece.addAttribute(.foregroundColor, value: color, range: range) }
        }
    }
}

/// Native text-table cells keep columns aligned and wrap within a cell.
/// Row metadata keeps VoiceOver's one-element-per-row reading structure.
@MainActor
enum ReplyTable {
    static let rowAttribute = NSAttributedString.Key("ClaudeNativeTableRow")
    static let cellPadding: CGFloat = 8

    static func render(_ content: TableContent, style: MarkdownRenderStyle) -> NSMutableAttributedString {
        let rows = [content.head] + content.rows
        let columns = rows.map(\.count).max() ?? 0
        let output = NSMutableAttributedString()
        guard columns > 0 else { return output }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        for (rowIndex, cells) in rows.enumerated() {
            for column in 0..<columns {
                let cell = column < cells.count ? cells[column] : InlineText(runs: [])
                let text = NSMutableAttributedString(attributedString:
                    AppKitMarkdownRenderer.attributedString(for: [.paragraph(cell)], style: style)
                )
                text.append(NSAttributedString(string: "\n"))
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setContentWidth(100 / CGFloat(columns), type: .percentageValueType)
                block.setWidth(cellPadding, type: .absoluteValueType, for: .padding)
                block.setWidth(Theme.hairlineWidth, type: .absoluteValueType, for: .border)
                block.setBorderColor(Theme.cardBorder)
                if rowIndex == 0 { block.backgroundColor = Theme.cardFill }
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                if column < content.columnAlignments.count {
                    switch content.columnAlignments[column] {
                    case .natural: paragraph.alignment = .natural
                    case .left: paragraph.alignment = .left
                    case .center: paragraph.alignment = .center
                    case .right: paragraph.alignment = .right
                    }
                }
                let range = NSRange(location: 0, length: text.length)
                text.addAttributes([.paragraphStyle: paragraph, rowAttribute: rowIndex], range: range)
                if rowIndex == 0 {
                    text.addAttribute(.font, value: NSFont.systemFont(ofSize: style.bodySize, weight: .semibold), range: range)
                }
                output.append(text)
            }
        }
        return output
    }
}

/// How a code line too long for its card wraps.
enum CodeWrap {
    /// The extra indent of a wrapped line's continuation, in spaces:
    /// Xcode's default for wrapped lines. A tab counts as this many too.
    static let continuationSpaces = 4
    /// Leading whitespace beyond this many characters doesn't push the
    /// continuation further right.
    static let maxIndentCharacters = 16
    /// Nor beyond this share of the narrowest conversation column, in
    /// points, so at Bigger Text deep indentation can't leave the wrapped
    /// part a sliver.
    static let maxIndentShare: CGFloat = 0.4
    static var maxIndentWidth: CGFloat { ChatLayout.conversationMinWidth * maxIndentShare }
}

/// A code block in a reply, as one text block across the column: the text
/// system insets its lines by the padding and spaces it from its neighbours
/// by the margin. It draws nothing itself; MessageRowView draws one rounded
/// card behind the whole block, so every line shares one even edge.
final class CodeCardBlock: NSTextBlock {
    /// The language shown in the card's top corner ("Swift"), if the fence
    /// named one, and the font it's drawn in.
    let caption: String?
    let captionFont: NSFont

    /// The caption's size as a share of the reply's body text.
    static let captionScale: CGFloat = 0.85

    init(caption: String?, bodySize: CGFloat) {
        self.caption = caption
        captionFont = .systemFont(ofSize: (bodySize * Self.captionScale).rounded(), weight: .medium)
        super.init()
        setContentWidth(100, type: .percentageValueType)
        setWidth(TranscriptLayout.codePadding, type: .absoluteValueType, for: .padding)
        // Room for the caption above the code: its line height, measured
        // from its font, so the label and the kept layout agree.
        if caption != nil {
            let captionLine = NSLayoutManager().defaultLineHeight(for: captionFont)
            setWidth(
                TranscriptLayout.codePadding + captionLine + TranscriptLayout.codeCaptionGap,
                type: .absoluteValueType, for: .padding, edge: .minY
            )
        }
        setWidth(TranscriptLayout.codeMargin, type: .absoluteValueType, for: .margin, edge: .minY)
        setWidth(TranscriptLayout.codeMargin, type: .absoluteValueType, for: .margin, edge: .maxY)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

