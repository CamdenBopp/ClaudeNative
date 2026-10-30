import CoreGraphics
import Foundation
import Testing
import ChatMarkdownCore
@testable import ChatTextLayout

struct BlockBitmapRendererTests {
    private func makeResult(_ content: BlockContent, width: CGFloat = 300) -> BlockLayoutResult {
        BlockLayoutEngine.layout(
            block: MarkdownBlock(
                id: BlockID(messageID: MessageID("bitmap-test"), birthOrder: 0),
                revision: .zero,
                content: content
            ),
            width: width,
            theme: .default,
            environment: RenderEnvironment()
        )
    }

    private func makePalette() -> DrawPalette {
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        return DrawPalette(text: black, rule: black, quoteBar: black, link: black)
    }

    @Test func rendersParagraphAtExactPixelSize() throws {
        let result = makeResult(.paragraph(.plain("Hello, bitmap world.")))
        let image = try #require(BlockBitmapRenderer.render(
            result: result, palette: makePalette(), scale: 3
        ))
        #expect(image.width == Int((result.size.width * 3).rounded(.up)))
        #expect(image.height == Int((result.size.height * 3).rounded(.up)))
    }

    @Test func renderedGlyphsProduceVisiblePixels() throws {
        let result = makeResult(.paragraph(.plain("Ink.")))
        let image = try #require(BlockBitmapRenderer.render(
            result: result, palette: makePalette(), scale: 2
        ))
        let data = try #require(image.dataProvider?.data as Data?)
        // Premultiplied BGRA: any nonzero byte means something was drawn.
        #expect(data.contains { $0 != 0 })
    }

    @Test func degenerateSizesReturnNil() {
        let empty = makeResult(.paragraph(.plain("")))
        #expect(BlockBitmapRenderer.render(result: empty, palette: makePalette(), scale: 2) == nil)

        let normal = makeResult(.paragraph(.plain("x")))
        #expect(BlockBitmapRenderer.render(result: normal, palette: makePalette(), scale: 0) == nil)
    }

    @Test func renderIsCallableOffMain() async throws {
        let result = makeResult(.heading(level: 1, text: .plain("Off-main render")))
        let palette = makePalette()
        let image = await Task.detached(priority: .utility) {
            BlockBitmapRenderer.render(result: result, palette: palette, scale: 2)
        }.value
        #expect(image != nil)
    }
}
