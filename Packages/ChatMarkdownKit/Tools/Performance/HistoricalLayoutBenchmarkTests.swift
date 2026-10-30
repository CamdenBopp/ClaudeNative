// Copy into an archived revision for the historical audit; see docs/PERFORMANCE.md.
import CoreGraphics
import Foundation
import Testing
import ChatMarkdownCore
@testable import ChatTextLayout

struct HistoricalLayoutBenchmarkTests {
    func measure(_ label: String, _ content: BlockContent, repeats: Int = 5, layouts: Int = 20) {
        let block = MarkdownBlock(id: BlockID(messageID: MessageID("layout-history"), birthOrder: 0), revision: .zero, content: content)
        _ = BlockLayoutEngine.layout(block: block, width: 480, theme: .default, environment: RenderEnvironment())
        var samples: [Double] = []
        var checksum = 0
        for _ in 0..<repeats {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<layouts {
                checksum += BlockLayoutEngine.layout(block: block, width: 480, theme: .default, environment: RenderEnvironment()).commands.count
            }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(layouts) / 1_000_000)
        }
        samples.sort()
        print("HISTLAYOUT \(label) median_ms=\(samples[samples.count / 2]) min_ms=\(samples[0]) checksum=\(checksum)")
        #expect(checksum > 0)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHAT_MARKDOWN_HISTORY_BENCHMARKS"] == "1")) func historicalLayoutWorkloads() {
        for count in [100, 400, 800] {
            let items: [[BlockContent]] = (0..<count).map { [.paragraph(.plain("Paragraph \($0) with words to show."))] }
            measure("warm-list-\(count)", .unorderedList(items: items))
            measure("warm-quote-\(count)", .blockQuote(items.flatMap { $0 }))
        }
        for count in [100, 400] {
            let rows: [[InlineText]] = (0..<count).map { [.plain("Name \($0)"), .plain("Value \($0)")] }
            let table = TableContent(columnAlignments: [.natural, .natural], head: [.plain("Name"), .plain("Value")], rows: rows)
            measure("warm-table-\(count)", .table(table))
        }
    }
}
