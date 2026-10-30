import Foundation
import Markdown

/// swift-markdown AST → our semantic block model. Internal: the public entry
/// point is `StreamingMessageAssembler`, which owns identity and deltas.
enum MarkdownConverter {
    /// A converted block plus its source range (1-based line/column, columns
    /// in UTF-8 bytes) — the assembler uses ranges to advance its frozen
    /// prefix during tail-only reparsing.
    struct ParsedBlock {
        let content: BlockContent
        let range: SourceRange?
    }

    static func parsedBlocks(from source: String) -> [ParsedBlock] {
        let document = Document(parsing: source)
        return document.blockChildren.compactMap { child in
            convert(child).map { ParsedBlock(content: $0, range: child.range) }
        }
    }

    static func blocks(from source: String) -> [BlockContent] {
        parsedBlocks(from: source).map(\.content)
    }

    // MARK: - Blocks

    private static func convert(_ markup: BlockMarkup) -> BlockContent? {
        switch markup {
        case let paragraph as Paragraph:
            return .paragraph(inlineText(paragraph.inlineChildren))
        case let heading as Heading:
            return .heading(level: heading.level, text: inlineText(heading.inlineChildren))
        case let code as CodeBlock:
            // The assembler downgrades `isClosed` on the tail block while the
            // stream is open and the fence is not yet closed.
            return .codeBlock(CodeBlockContent(
                languageHint: code.language,
                rawText: code.code,
                isClosed: true
            ))
        case let quote as BlockQuote:
            return .blockQuote(quote.blockChildren.compactMap(convert))
        case let list as UnorderedList:
            return .unorderedList(items: list.listItems.map { item in
                item.blockChildren.compactMap(convert)
            })
        case let list as OrderedList:
            return .orderedList(start: 1, items: list.listItems.map { item in
                item.blockChildren.compactMap(convert)
            })
        case let table as Markdown.Table:
            return .table(tableContent(table))
        case is ThematicBreak:
            return .thematicBreak
        case let html as HTMLBlock:
            return .htmlBlock(literal: html.rawHTML)
        default:
            // Unsupported block kinds degrade to their plain Markdown source
            // rather than disappearing.
            let text = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .paragraph(.plain(text))
        }
    }

    private static func tableContent(_ table: Markdown.Table) -> TableContent {
        let alignments: [ColumnAlignment] = table.columnAlignments.map { alignment in
            switch alignment {
            case .some(.left): return .left
            case .some(.center): return .center
            case .some(.right): return .right
            case .none: return .natural
            }
        }
        let head = table.head.children.compactMap { child -> InlineText? in
            guard let cell = child as? Markdown.Table.Cell else { return nil }
            return inlineText(cell.inlineChildren)
        }
        let rows = table.body.children.compactMap { child -> [InlineText]? in
            guard let row = child as? Markdown.Table.Row else { return nil }
            return row.children.compactMap { rowChild -> InlineText? in
                guard let cell = rowChild as? Markdown.Table.Cell else { return nil }
                return inlineText(cell.inlineChildren)
            }
        }
        return TableContent(columnAlignments: alignments, head: head, rows: rows)
    }

    // MARK: - Inlines

    private static func inlineText(_ children: some Sequence<InlineMarkup>) -> InlineText {
        var runs: [InlineRun] = []
        appendRuns(from: children, attributes: [], linkDestination: nil, into: &runs)
        return InlineText(runs: merged(runs))
    }

    private static func appendRuns(
        from children: some Sequence<InlineMarkup>,
        attributes: InlineRun.Attributes,
        linkDestination: String?,
        into runs: inout [InlineRun]
    ) {
        for child in children {
            switch child {
            case let text as Markdown.Text:
                runs.append(InlineRun(
                    text: text.string,
                    attributes: attributes,
                    linkDestination: linkDestination
                ))
            case let emphasis as Emphasis:
                appendRuns(
                    from: emphasis.inlineChildren,
                    attributes: attributes.union(.italic),
                    linkDestination: linkDestination,
                    into: &runs
                )
            case let strong as Strong:
                appendRuns(
                    from: strong.inlineChildren,
                    attributes: attributes.union(.bold),
                    linkDestination: linkDestination,
                    into: &runs
                )
            case let strikethrough as Strikethrough:
                appendRuns(
                    from: strikethrough.inlineChildren,
                    attributes: attributes.union(.strikethrough),
                    linkDestination: linkDestination,
                    into: &runs
                )
            case let code as InlineCode:
                runs.append(InlineRun(
                    text: code.code,
                    attributes: attributes.union(.code),
                    linkDestination: linkDestination
                ))
            case let link as Markdown.Link:
                appendRuns(
                    from: link.inlineChildren,
                    attributes: attributes,
                    linkDestination: link.destination ?? linkDestination,
                    into: &runs
                )
            case let image as Markdown.Image:
                let alt = plainText(of: image)
                runs.append(InlineRun(
                    text: alt.isEmpty ? "image" : alt,
                    attributes: attributes,
                    linkDestination: linkDestination,
                    image: ImageRef(source: image.source, altText: alt)
                ))
            case is SoftBreak:
                runs.append(InlineRun(text: " ", attributes: attributes, linkDestination: linkDestination))
            case is LineBreak:
                runs.append(InlineRun(text: "\n", attributes: attributes, linkDestination: linkDestination))
            case let html as InlineHTML:
                // Literal text, styled as code; never interpreted.
                runs.append(InlineRun(text: html.rawHTML, attributes: attributes.union(.code)))
            default:
                let fallback = child.format()
                if !fallback.isEmpty {
                    runs.append(InlineRun(text: fallback, attributes: attributes, linkDestination: linkDestination))
                }
            }
        }
    }

    private static func plainText(of markup: Markup) -> String {
        var result = ""
        collectPlainText(markup, into: &result)
        return result
    }

    private static func collectPlainText(_ markup: Markup, into result: inout String) {
        if let text = markup as? Markdown.Text {
            result += text.string
            return
        }
        for child in markup.children {
            collectPlainText(child, into: &result)
        }
    }

    /// Coalesces adjacent runs with identical styling so downstream attributed
    /// strings and accessibility labels see the minimum run count.
    private static func merged(_ runs: [InlineRun]) -> [InlineRun] {
        var output: [InlineRun] = []
        for run in runs {
            if var last = output.last,
               last.attributes == run.attributes,
               last.linkDestination == run.linkDestination,
               last.image == nil, run.image == nil {
                last.text += run.text
                output[output.count - 1] = last
            } else {
                output.append(run)
            }
        }
        return output
    }
}
