import CoreGraphics
import Testing
import ChatMarkdownCore
@testable import ChatTextLayout

struct MeasuredHeightTests {
    private func makeDocument() -> MarkdownDocument {
        let assembler = StreamingMessageAssembler(messageID: MessageID("measure-test"))
        assembler.append("""
        # Title

        A paragraph of body text that will wrap at narrow widths and \
        contribute real height.

        ```swift
        let a = 1
        let b = 2
        let c = 3
        ```

        Closing thoughts paragraph.
        """)
        return assembler.finish().document
    }

    @Test func measuredHeightMatchesManualStackingSum() async throws {
        let scheduler = BlockLayoutScheduler()
        let document = makeDocument()
        try #require(document.blocks.count == 4)
        let metrics = MessageLayoutMetrics()
        let environment = RenderEnvironment()

        let measured = await scheduler.measuredContentHeight(
            of: document, width: 320, theme: .default, environment: environment, metrics: metrics
        )

        var expected: CGFloat = 0
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { expected += metrics.blockSpacing }
            if case .codeBlock(let code) = block.content {
                expected += MessageStacking.codeBlockHeight(
                    lineCount: MessageStacking.codeLineCount(forRawText: code.rawText),
                    lineHeight: metrics.codeLineHeight,
                    metrics: metrics
                )
            } else {
                expected += BlockLayoutEngine.layout(
                    block: block, width: 320, theme: .default, environment: environment
                ).size.height
            }
        }
        #expect(measured == expected)
        #expect(measured > 100)
    }

    @Test func measurementWarmsTheLayoutCache() async {
        let scheduler = BlockLayoutScheduler()
        let document = makeDocument()
        let metrics = MessageLayoutMetrics()
        let environment = RenderEnvironment()

        let first = await scheduler.measuredContentHeight(
            of: document, width: 320, theme: .default, environment: environment, metrics: metrics
        )
        let computesAfterFirst = await scheduler.computeCount
        #expect(computesAfterFirst == 3) // heading + 2 paragraphs; code costs no layout

        // Second measurement: all cache hits.
        let second = await scheduler.measuredContentHeight(
            of: document, width: 320, theme: .default, environment: environment, metrics: metrics
        )
        let computesAfterSecond = await scheduler.computeCount
        #expect(computesAfterSecond == computesAfterFirst)
        #expect(first == second)

        // A display request for the same blocks also hits the warmed cache.
        var iterator = await scheduler.commits().makeAsyncIterator()
        await scheduler.layoutAll(document, width: 320, theme: .default, environment: environment)
        let commit = await iterator.next()
        #expect(commit?.fromCache == true)
        let computesAfterDisplay = await scheduler.computeCount
        #expect(computesAfterDisplay == computesAfterFirst)
    }

    @Test func widthChangesProduceDifferentHeights() async {
        let scheduler = BlockLayoutScheduler()
        let document = makeDocument()
        let metrics = MessageLayoutMetrics()
        let environment = RenderEnvironment()

        let wide = await scheduler.measuredContentHeight(
            of: document, width: 700, theme: .default, environment: environment, metrics: metrics
        )
        let narrow = await scheduler.measuredContentHeight(
            of: document, width: 200, theme: .default, environment: environment, metrics: metrics
        )
        #expect(narrow > wide)
    }
}
