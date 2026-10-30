import CoreGraphics
import Foundation
import Testing
import ChatMarkdownCore
@testable import ChatTextLayout

/// A simulator verification flagged transiently "corrupted" table rendering
/// mid-stream. Partial-markdown intermediate states legitimately look odd
/// (half-streamed cell text, shifting column widths), but actual glyph
/// overlap would be an engine bug: within one layout result, cell text rects
/// must never intersect, at any intermediate revision, at any width.
struct StreamingTableGeometryTests {
    private static let tableMarkdown = """
    Mid-stream behavior:

    | Feature | Engine | Thread |
    |---|---|---|
    | Rich text | CoreText line layout | Background |
    | Code blocks | Line-oriented, only visible text lines | Background |
    | Heights | Shared LRU cache, exact precomputed values | Background |

    And a trailing paragraph.
    """

    @Test(arguments: [CGFloat(240), 320, 375, 700])
    func streamedTableCellsNeverOverlap(width: CGFloat) {
        let assembler = StreamingMessageAssembler(messageID: MessageID("table-geo-\(Int(width))"))
        let source = Self.tableMarkdown
        var index = source.startIndex

        while index < source.endIndex {
            // Small odd-sized chunks so boundaries land mid-cell, mid-pipe,
            // and mid-delimiter-row.
            let end = source.index(index, offsetBy: 7, limitedBy: source.endIndex) ?? source.endIndex
            assembler.append(String(source[index..<end]))
            index = end
            assertNoOverlap(in: assembler.currentDocument, width: width)
        }
        assembler.finish()
        assertNoOverlap(in: assembler.currentDocument, width: width)
    }

    private func assertNoOverlap(in document: MarkdownDocument, width: CGFloat) {
        for block in document.blocks where block.content.kind == .table {
            let result = BlockLayoutEngine.layout(
                block: block, width: width, theme: .default, environment: RenderEnvironment()
            )
            var rects: [CGRect] = []
            for command in result.commands {
                if case .text(let layout, let origin) = command {
                    guard layout.size.height > 0, layout.size.width > 0 else { continue }
                    rects.append(CGRect(origin: origin, size: layout.size))
                }
            }
            for i in rects.indices {
                for j in rects.indices where j > i {
                    // Shrink slightly so shared edges don't count as overlap.
                    let a = rects[i].insetBy(dx: 0.25, dy: 0.25)
                    let b = rects[j].insetBy(dx: 0.25, dy: 0.25)
                    #expect(
                        !a.intersects(b),
                        "cell rects overlap at width \(width): \(rects[i]) vs \(rects[j]) — revision \(block.revision.rawValue), source-state table with \(rects.count) cells"
                    )
                    if a.intersects(b) { return }
                }
            }
        }
    }
}
