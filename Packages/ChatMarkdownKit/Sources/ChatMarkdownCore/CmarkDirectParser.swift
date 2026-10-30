import Foundation
import Markdown
import cmark_gfm
import cmark_gfm_extensions

/// Parses Markdown straight from cmark-gfm's C node tree into our value model,
/// skipping swift-markdown's intermediate class AST.
///
/// swift-markdown builds a full tree of `Markup` **class** nodes and we then
/// re-walk it into value types — measured at ~14× the cost of the raw cmark
/// parse (6.9 ms vs 0.49 ms for an 800-block document). This walks cmark's own
/// tree (the same reference parser swift-markdown uses underneath) once, directly
/// into `BlockContent`, so the result is the same parse with none of the class
/// allocation.
///
/// Correctness is not asserted by this comment: `CmarkDirectParityTests`
/// differential-tests every block this produces against `MarkdownConverter`
/// (swift-markdown) over a corpus and fuzzed inputs. swift-markdown stays as the
/// oracle; this is only the fast path.
enum CmarkDirectParser {
    static func parsedBlocks(from source: String) -> [MarkdownConverter.ParsedBlock] {
        cmark_gfm_core_extensions_ensure_registered()
        // Exactly the option set `Document(parsing:)` uses by default, so the
        // parse is identical: TABLE_SPANS, SMART (curly quotes, en/em dashes —
        // omitting it renders `---` as literal instead of `—`), and SOURCEPOS
        // for the block ranges the assembler's freeze logic reads.
        let options = CMARK_OPT_TABLE_SPANS | CMARK_OPT_SMART | CMARK_OPT_SOURCEPOS
        guard let parser = cmark_parser_new(options) else { return [] }
        defer { cmark_parser_free(parser) }
        cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension("table"))
        cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension("strikethrough"))
        cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension("tasklist"))
        let byteCount = source.utf8.count
        source.withCString { cmark_parser_feed(parser, $0, byteCount) }
        guard let document = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(document) }

        var blocks: [MarkdownConverter.ParsedBlock] = []
        var child = cmark_node_first_child(document)
        while let node = child {
            if let content = convert(node) {
                blocks.append(MarkdownConverter.ParsedBlock(content: content, range: range(of: node)))
            }
            child = cmark_node_next(node)
        }
        return blocks
    }

    // MARK: - Blocks

    private static func convert(_ node: UnsafeMutablePointer<cmark_node>) -> BlockContent? {
        switch cmark_node_get_type(node) {
        case CMARK_NODE_PARAGRAPH:
            return .paragraph(inlineText(of: node))
        case CMARK_NODE_HEADING:
            return .heading(level: Int(cmark_node_get_heading_level(node)), text: inlineText(of: node))
        case CMARK_NODE_CODE_BLOCK:
            let info = string(cmark_node_get_fence_info(node))
            return .codeBlock(CodeBlockContent(
                languageHint: info.isEmpty ? nil : info,
                rawText: string(cmark_node_get_literal(node)),
                isClosed: true
            ))
        case CMARK_NODE_BLOCK_QUOTE:
            return .blockQuote(childBlocks(of: node))
        case CMARK_NODE_LIST:
            let items = listItems(of: node)
            return cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
                ? .orderedList(start: 1, items: items)
                : .unorderedList(items: items)
        case CMARK_NODE_THEMATIC_BREAK:
            return .thematicBreak
        case CMARK_NODE_HTML_BLOCK:
            return .htmlBlock(literal: string(cmark_node_get_literal(node)))
        default:
            // Extension blocks (table) carry a custom type; recognize by name.
            switch string(cmark_node_get_type_string(node)) {
            case "table":
                return .table(tableContent(node))
            default:
                // Unsupported block kinds degrade to their rendered source, as
                // `MarkdownConverter` does with `markup.format()`.
                let text = renderedCommonMark(node).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : .paragraph(.plain(text))
            }
        }
    }

    /// The block children of a container (block quote / list item), converted.
    private static func childBlocks(of node: UnsafeMutablePointer<cmark_node>) -> [BlockContent] {
        var result: [BlockContent] = []
        var child = cmark_node_first_child(node)
        while let n = child {
            if let content = convert(n) { result.append(content) }
            child = cmark_node_next(n)
        }
        return result
    }

    /// A list's items (each item's block children).
    private static func listItems(of list: UnsafeMutablePointer<cmark_node>) -> [[BlockContent]] {
        var items: [[BlockContent]] = []
        var item = cmark_node_first_child(list)
        while let n = item {
            if cmark_node_get_type(n) == CMARK_NODE_ITEM { items.append(childBlocks(of: n)) }
            item = cmark_node_next(n)
        }
        return items
    }

    private static func tableContent(_ table: UnsafeMutablePointer<cmark_node>) -> TableContent {
        let columnCount = Int(cmark_gfm_extensions_get_table_columns(table))
        let alignmentBytes = cmark_gfm_extensions_get_table_alignments(table)
        let alignments: [ColumnAlignment] = (0..<max(0, columnCount)).map { column in
            switch alignmentBytes?[column] {
            case UInt8(ascii: "l"): return .left
            case UInt8(ascii: "c"): return .center
            case UInt8(ascii: "r"): return .right
            default: return .natural
            }
        }
        var head: [InlineText] = []
        var rows: [[InlineText]] = []
        var row = cmark_node_first_child(table)
        while let r = row {
            let cells = cells(of: r)
            // The first row is the header (cmark emits it first); the rest body.
            if head.isEmpty && rows.isEmpty { head = cells } else { rows.append(cells) }
            row = cmark_node_next(r)
        }
        return TableContent(columnAlignments: alignments, head: head, rows: rows)
    }

    private static func cells(of row: UnsafeMutablePointer<cmark_node>) -> [InlineText] {
        var cells: [InlineText] = []
        var cell = cmark_node_first_child(row)
        while let c = cell {
            if string(cmark_node_get_type_string(c)) == "table_cell" { cells.append(inlineText(of: c)) }
            cell = cmark_node_next(c)
        }
        return cells
    }

    // MARK: - Inlines

    private static func inlineText(of node: UnsafeMutablePointer<cmark_node>) -> InlineText {
        var runs: [InlineRun] = []
        appendRuns(from: node, attributes: [], linkDestination: nil, into: &runs)
        return InlineText(runs: merged(runs))
    }

    private static func appendRuns(
        from parent: UnsafeMutablePointer<cmark_node>,
        attributes: InlineRun.Attributes,
        linkDestination: String?,
        into runs: inout [InlineRun]
    ) {
        var child = cmark_node_first_child(parent)
        while let node = child {
            defer { child = cmark_node_next(node) }
            switch cmark_node_get_type(node) {
            case CMARK_NODE_TEXT:
                runs.append(InlineRun(text: string(cmark_node_get_literal(node)), attributes: attributes, linkDestination: linkDestination))
            case CMARK_NODE_EMPH:
                appendRuns(from: node, attributes: attributes.union(.italic), linkDestination: linkDestination, into: &runs)
            case CMARK_NODE_STRONG:
                appendRuns(from: node, attributes: attributes.union(.bold), linkDestination: linkDestination, into: &runs)
            case CMARK_NODE_CODE:
                runs.append(InlineRun(text: string(cmark_node_get_literal(node)), attributes: attributes.union(.code), linkDestination: linkDestination))
            case CMARK_NODE_LINK:
                appendRuns(from: node, attributes: attributes, linkDestination: emptyToNil(string(cmark_node_get_url(node))) ?? linkDestination, into: &runs)
            case CMARK_NODE_IMAGE:
                let alt = plainText(of: node)
                runs.append(InlineRun(
                    text: alt.isEmpty ? "image" : alt,
                    attributes: attributes,
                    linkDestination: linkDestination,
                    image: ImageRef(source: emptyToNil(string(cmark_node_get_url(node))), altText: alt)
                ))
            case CMARK_NODE_SOFTBREAK:
                runs.append(InlineRun(text: " ", attributes: attributes, linkDestination: linkDestination))
            case CMARK_NODE_LINEBREAK:
                runs.append(InlineRun(text: "\n", attributes: attributes, linkDestination: linkDestination))
            case CMARK_NODE_HTML_INLINE:
                // Literal text, styled as code; never interpreted.
                runs.append(InlineRun(text: string(cmark_node_get_literal(node)), attributes: attributes.union(.code)))
            default:
                switch string(cmark_node_get_type_string(node)) {
                case "strikethrough":
                    appendRuns(from: node, attributes: attributes.union(.strikethrough), linkDestination: linkDestination, into: &runs)
                default:
                    let fallback = renderedCommonMark(node).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !fallback.isEmpty {
                        runs.append(InlineRun(text: fallback, attributes: attributes, linkDestination: linkDestination))
                    }
                }
            }
        }
    }

    /// Concatenated descendant text (an image's alt text).
    private static func plainText(of node: UnsafeMutablePointer<cmark_node>) -> String {
        if cmark_node_get_type(node) == CMARK_NODE_TEXT { return string(cmark_node_get_literal(node)) }
        var result = ""
        var child = cmark_node_first_child(node)
        while let n = child { result += plainText(of: n); child = cmark_node_next(n) }
        return result
    }

    /// Coalesces adjacent runs with identical styling — the same rule as
    /// `MarkdownConverter.merged`, so run counts match the oracle.
    private static func merged(_ runs: [InlineRun]) -> [InlineRun] {
        var output: [InlineRun] = []
        for run in runs {
            let lastIndex = output.count - 1
            if lastIndex >= 0,
               output[lastIndex].attributes == run.attributes,
               output[lastIndex].linkDestination == run.linkDestination,
               output[lastIndex].image == nil, run.image == nil {
                // Mutate the stored run directly. Copying output.last into a
                // local value first makes each append copy the growing String,
                // quadratic for long paragraphs with many soft line breaks.
                output[lastIndex].text += run.text
            } else {
                output.append(run)
            }
        }
        return output
    }

    // MARK: - Helpers

    private static func string(_ cString: UnsafePointer<CChar>?) -> String {
        guard let cString else { return "" }
        return String(cString: cString)
    }

    private static func emptyToNil(_ s: String) -> String? { s.isEmpty ? nil : s }

    private static func range(of node: UnsafeMutablePointer<cmark_node>) -> SourceRange? {
        let startLine = Int(cmark_node_get_start_line(node))
        let startColumn = Int(cmark_node_get_start_column(node))
        guard startLine > 0, startColumn > 0 else { return nil }
        let endLine = Int(cmark_node_get_end_line(node))
        let endColumn = Int(cmark_node_get_end_column(node))
        let start = SourceLocation(line: startLine, column: startColumn, source: nil)
        // cmark end columns are inclusive; the range's upper bound is exclusive.
        let end = SourceLocation(line: max(endLine, startLine), column: max(endColumn + 1, startColumn), source: nil)
        return start..<end
    }

    private static func renderedCommonMark(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        guard let c = cmark_render_commonmark(node, CMARK_OPT_DEFAULT, 0) else { return "" }
        defer { free(c) }
        return String(cString: c)
    }
}
