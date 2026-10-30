import CoreGraphics
import Foundation
import Testing
import ChatMarkdownCore
@testable import ChatTextLayout

private let environment = RenderEnvironment()

private func layoutBlock(_ content: BlockContent, width: CGFloat = 320, birthOrder: Int = 0) -> (MarkdownBlock, BlockLayoutResult) {
    let block = MarkdownBlock(
        id: BlockID(messageID: MessageID("a11y-test"), birthOrder: birthOrder),
        revision: .zero,
        content: content
    )
    let layout = BlockLayoutEngine.layout(block: block, width: width, theme: .default, environment: environment)
    return (block, layout)
}

struct AccessibilityProjectorTests {
    @Test func paragraphProjectsOneBodyElement() {
        let (block, layout) = layoutBlock(.paragraph(.plain("Plain spoken text.")))
        let elements = AccessibilityProjector.elements(for: block, layout: layout, origin: CGPoint(x: 0, y: 40))
        #expect(elements.count == 1)
        #expect(elements[0].id == .init(blockID: block.id, slot: .body))
        #expect(elements[0].label == "Plain spoken text.")
        #expect(elements[0].frame.minY == 40)
        #expect(elements[0].kind == .blockText(.paragraph))
    }

    @Test func linksBecomeSeparateElementsAfterTheBody() throws {
        let text = InlineText(runs: [
            InlineRun(text: "Read "),
            InlineRun(text: "the guide", linkDestination: "https://example.com/guide"),
            InlineRun(text: " and "),
            InlineRun(text: "the reference", linkDestination: "https://example.com/ref"),
            InlineRun(text: "."),
        ])
        let (block, layout) = layoutBlock(.paragraph(text))
        let elements = AccessibilityProjector.elements(for: block, layout: layout, origin: .zero)

        try #require(elements.count == 3)
        #expect(elements[0].kind == .blockText(.paragraph))
        #expect(elements[1].kind == .link(destination: "https://example.com/guide"))
        #expect(elements[1].label == "the guide")
        #expect(elements[2].kind == .link(destination: "https://example.com/ref"))
        #expect(elements[2].label == "the reference")
        // Link frames sit inside the body frame (±1pt typographic overhang:
        // run bounds vs the ceiled framesetter size can differ subpixel).
        #expect(elements[0].frame.insetBy(dx: -1, dy: -1).contains(elements[1].frame))
    }

    @Test func elementIdentityIsStableAcrossRevisions() {
        let text1 = InlineText(runs: [
            InlineRun(text: "Growing "),
            InlineRun(text: "link", linkDestination: "https://example.com"),
        ])
        let text2 = InlineText(runs: [
            InlineRun(text: "Growing paragraph with more words "),
            InlineRun(text: "link", linkDestination: "https://example.com"),
        ])
        let id = BlockID(messageID: MessageID("a11y-test"), birthOrder: 5)
        let block1 = MarkdownBlock(id: id, revision: .zero, content: .paragraph(text1))
        let block2 = MarkdownBlock(id: id, revision: BlockRevision(1), content: .paragraph(text2))
        let layout1 = BlockLayoutEngine.layout(block: block1, width: 320, theme: .default, environment: environment)
        let layout2 = BlockLayoutEngine.layout(block: block2, width: 320, theme: .default, environment: environment)

        let ids1 = AccessibilityProjector.elements(for: block1, layout: layout1, origin: .zero).map(\.id)
        let ids2 = AccessibilityProjector.elements(for: block2, layout: layout2, origin: .zero).map(\.id)
        // Same block, same slots ⇒ same identity ⇒ VoiceOver focus survives.
        #expect(ids1 == ids2)
    }

    @Test func codeBlocksProjectNothingHere() {
        let (block, layout) = layoutBlock(.codeBlock(CodeBlockContent(
            languageHint: "swift", rawText: "let x = 1\n", isClosed: true
        )))
        let elements = AccessibilityProjector.elements(for: block, layout: layout, origin: .zero)
        #expect(elements.isEmpty)
    }

    @Test func headingRoleCarriesThrough() {
        let (block, layout) = layoutBlock(.heading(level: 2, text: .plain("Section")))
        let elements = AccessibilityProjector.elements(for: block, layout: layout, origin: .zero)
        #expect(elements.first?.kind == .blockText(.heading(level: 2)))
    }

    @Test func listProjectsOneElementPerItemInsteadOfOneRunOnSentence() throws {
        let (block, layout) = layoutBlock(.unorderedList(items: [
            [.paragraph(.plain("First"))],
            [.paragraph(.plain("Second"))],
            [.paragraph(.plain("Third"))],
        ]))
        let elements = AccessibilityProjector.elements(for: block, layout: layout, origin: CGPoint(x: 0, y: 10))

        try #require(elements.count == 3)
        #expect(elements[0].id == .init(blockID: block.id, slot: .listItem(0)))
        #expect(elements[0].label == "Item 1 of 3: First")
        #expect(elements[1].label == "Item 2 of 3: Second")
        #expect(elements[2].label == "Item 3 of 3: Third")
        #expect(elements.allSatisfy { $0.kind == .blockText(.list) })
        // Frames are offset into the container and stack top to bottom.
        #expect(elements[0].frame.minY == 10)
        #expect(elements[1].frame.minY > elements[0].frame.minY)
        #expect(elements[2].frame.minY > elements[1].frame.minY)
    }

    @Test func listLinksInterleaveAfterTheirOwnItemInsteadOfBatchingAtTheEnd() throws {
        let firstItemText = InlineText(runs: [
            InlineRun(text: "Read "),
            InlineRun(text: "the guide", linkDestination: "https://example.com/guide"),
            InlineRun(text: " first."),
        ])
        let (block, layout) = layoutBlock(.unorderedList(items: [
            [.paragraph(firstItemText)],
            [.paragraph(.plain("Second, with no link."))],
            [.paragraph(.plain("Third, with no link."))],
        ]))
        let elements = AccessibilityProjector.elements(for: block, layout: layout, origin: .zero)

        // The link belongs to item 1 and must be reachable right after it —
        // not after every item in the list.
        try #require(elements.count == 4)
        #expect(elements[0].id == .init(blockID: block.id, slot: .listItem(0)))
        #expect(elements[1].kind == .link(destination: "https://example.com/guide"))
        #expect(elements[1].label == "the guide")
        #expect(elements[2].id == .init(blockID: block.id, slot: .listItem(1)))
        #expect(elements[3].id == .init(blockID: block.id, slot: .listItem(2)))
    }

    @Test func linkRegionsCarryVisibleText() throws {
        let text = InlineText(runs: [
            InlineRun(text: "See "),
            InlineRun(text: "the changelog", linkDestination: "https://example.com/log"),
        ])
        let (_, layout) = layoutBlock(.paragraph(text))
        try #require(layout.links.count == 1)
        #expect(layout.links[0].text == "the changelog")
        #expect(layout.links[0].destination == "https://example.com/log")
    }
}
