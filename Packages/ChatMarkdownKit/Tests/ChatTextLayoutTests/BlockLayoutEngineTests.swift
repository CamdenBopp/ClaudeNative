import CoreGraphics
import Foundation
import Testing
import ChatMarkdownCore
@testable import ChatTextLayout

private func makeBlock(_ content: BlockContent, birthOrder: Int = 0) -> MarkdownBlock {
    MarkdownBlock(
        id: BlockID(messageID: MessageID("layout-test"), birthOrder: birthOrder),
        revision: .zero,
        content: content
    )
}

private let environment = RenderEnvironment()

struct BlockLayoutEngineTests {
    @Test func paragraphReportsTightWidth() {
        let result = BlockLayoutEngine.layout(
            block: makeBlock(.paragraph(.plain("Short."))),
            width: 400, theme: .default, environment: environment
        )
        #expect(result.size.width > 0)
        #expect(result.size.width < 200)
        #expect(result.size.height > 0)
        #expect(result.accessibility.role == .paragraph)
        #expect(result.accessibility.label == "Short.")
    }

    @Test func headingIsTallerThanBodyAndCarriesRole() {
        let text = InlineText.plain("Section title")
        let paragraph = BlockLayoutEngine.layout(
            block: makeBlock(.paragraph(text)),
            width: 400, theme: .default, environment: environment
        )
        let heading = BlockLayoutEngine.layout(
            block: makeBlock(.heading(level: 1, text: text)),
            width: 400, theme: .default, environment: environment
        )
        #expect(heading.size.height > paragraph.size.height)
        #expect(heading.accessibility.role == .heading(level: 1))
    }

    @Test func quoteIndentsContentAndDrawsBar() {
        let result = BlockLayoutEngine.layout(
            block: makeBlock(.blockQuote([.paragraph(.plain("Quoted wisdom."))])),
            width: 300, theme: .default, environment: environment
        )
        var sawBar = false
        var sawIndentedText = false
        for command in result.commands {
            switch command {
            case .quoteBar(let rect):
                sawBar = true
                #expect(rect.minX == 0)
                #expect(rect.height > 0)
            case .text(_, let origin):
                sawIndentedText = origin.x >= TextTheme.default.quoteIndent || sawIndentedText
            case .rule:
                break
            }
        }
        #expect(sawBar)
        #expect(sawIndentedText)
        #expect(result.accessibility.label.hasPrefix("Quote:"))
    }

    @Test func orderedListNumbersMarkersFromStart() throws {
        let result = BlockLayoutEngine.layout(
            block: makeBlock(.orderedList(start: 3, items: [
                [.paragraph(.plain("third"))],
                [.paragraph(.plain("fourth"))],
            ])),
            width: 300, theme: .default, environment: environment
        )
        // Two markers + two item paragraphs.
        let textCommands = result.commands.filter {
            if case .text = $0 { return true } else { return false }
        }
        #expect(textCommands.count == 4)
        #expect(result.size.height > 0)
        #expect(result.accessibility.role == .list)
        #expect(result.accessibility.label.contains("2 items"))
        try #require(result.listItems.count == 2)
        #expect(result.listItems[0].label == "Item 1 of 2: third")
        #expect(result.listItems[1].label == "Item 2 of 2: fourth")
        #expect(result.listItems[0].frame.minY == 0)
        #expect(result.listItems[1].frame.minY > result.listItems[0].frame.maxY)
    }

    @Test func nestedListItemsFlattenAsTheirOwnSwipeStopsAfterTheirParent() throws {
        let result = BlockLayoutEngine.layout(
            block: makeBlock(.unorderedList(items: [
                [
                    .paragraph(.plain("Guided Journeys: use button actions.")),
                    .unorderedList(items: [
                        [.paragraph(.plain("Example: a Need Help button."))],
                    ]),
                ],
                [.paragraph(.plain("Information Hierarchy: use headings."))],
            ])),
            width: 300, theme: .default, environment: environment
        )
        // Parent item 1, its nested sub-item, then top-level item 2 — never
        // folded into "List with 1 item: ..." as part of item 1's own label.
        try #require(result.listItems.count == 3)
        #expect(result.listItems[0].label == "Item 1 of 2: Guided Journeys: use button actions.")
        #expect(result.listItems[1].label == "Item 1 of 1: Example: a Need Help button.")
        #expect(result.listItems[2].label == "Item 2 of 2: Information Hierarchy: use headings.")
        // The nested item sits below its parent and above the next top-level item.
        #expect(result.listItems[1].frame.minY > result.listItems[0].frame.minY)
        #expect(result.listItems[2].frame.minY > result.listItems[1].frame.minY)
    }

    @Test func tableKeepsNaturalWidthAndDrawsGrid() {
        let table = TableContent(
            columnAlignments: [.natural, .natural],
            head: [.plain("Name"), .plain("Value")],
            rows: [
                [.plain("alpha"), .plain("1")],
                [.plain("beta with a rather long description that never wraps"), .plain("2")],
            ]
        )
        let result = BlockLayoutEngine.layout(
            block: makeBlock(.table(table)),
            width: 320, theme: .default, environment: environment
        )
        // A long cell keeps its full single-line width, so the table overflows
        // the 320pt bubble instead of squishing/clipping the column — the host
        // scrolls it horizontally.
        #expect(result.size.width > 320)
        let ruleCount = result.commands.filter {
            if case .rule = $0 { return true } else { return false }
        }.count
        #expect(ruleCount >= 6) // 4 horizontal + 3 vertical minimum
        #expect(result.accessibility.label.contains("2 columns"))
        #expect(result.accessibility.label.contains("2 rows"))
    }

    @Test func tableWidthIsViewportIndependent() {
        let table = TableContent(
            columnAlignments: [.natural, .natural],
            head: [.plain("Name"), .plain("Value")],
            rows: [
                [.plain("alpha with several words"), .plain("first")],
                [.plain("beta"), .plain("second value here")],
            ]
        )
        func width(at bubble: CGFloat) -> CGFloat {
            BlockLayoutEngine.layout(
                block: makeBlock(.table(table)),
                width: bubble, theme: .default, environment: environment
            ).size.width
        }
        // Columns are sized to content, not the bubble: same table geometry at a
        // narrow and a wide bubble (the difference is scroll extent, not layout).
        #expect(width(at: 240) == width(at: 700))
    }

    @Test func linkRegionsCarryGeometry() throws {
        let text = InlineText(runs: [
            InlineRun(text: "Read "),
            InlineRun(text: "the documentation", linkDestination: "https://example.com/docs"),
            InlineRun(text: " today."),
        ])
        let result = BlockLayoutEngine.layout(
            block: makeBlock(.paragraph(text)),
            width: 400, theme: .default, environment: environment
        )
        try #require(result.links.count == 1)
        let link = result.links[0]
        #expect(link.destination == "https://example.com/docs")
        try #require(!link.rects.isEmpty)
        let rect = link.rects[0]
        #expect(rect.width > 10)
        #expect(rect.height > 8)
        #expect(rect.minX > 0) // "Read " precedes the link
        #expect(rect.maxY <= result.size.height + 0.5)
    }

    @Test func wrappedLinkProducesMultipleRects() throws {
        let text = InlineText(runs: [
            InlineRun(
                text: "a very long link label that will definitely wrap across lines",
                linkDestination: "https://example.com/wrap"
            ),
        ])
        let result = BlockLayoutEngine.layout(
            block: makeBlock(.paragraph(text)),
            width: 140, theme: .default, environment: environment
        )
        try #require(result.links.count == 1)
        #expect(result.links[0].rects.count >= 2)
    }

    @Test func thematicBreakIsDividerWithRule() {
        let result = BlockLayoutEngine.layout(
            block: makeBlock(.thematicBreak),
            width: 300, theme: .default, environment: environment
        )
        #expect(result.accessibility.label == "Divider")
        #expect(result.commands.count == 1)
        #expect(result.size.height == TextTheme.default.thematicBreakHeight)
    }

    @Test func estimatedCostGrowsWithContent() {
        let short = BlockLayoutEngine.layout(
            block: makeBlock(.paragraph(.plain("hi"))),
            width: 300, theme: .default, environment: environment
        )
        let long = BlockLayoutEngine.layout(
            block: makeBlock(.paragraph(.plain(String(repeating: "many words wrap onto many lines ", count: 30)))),
            width: 300, theme: .default, environment: environment
        )
        #expect(long.estimatedCost > short.estimatedCost)
    }
}
