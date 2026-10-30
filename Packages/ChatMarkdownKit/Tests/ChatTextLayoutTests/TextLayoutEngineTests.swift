import CoreGraphics
import Foundation
import Testing
import ChatMarkdownCore
@testable import ChatTextLayout

struct TextLayoutEngineTests {
    @Test func wrappingProducesMultipleLines() {
        let text = InlineText.plain(
            "The quick brown fox jumps over the lazy dog, repeatedly, until the line must wrap."
        )
        let attributed = AttributedTextBuilder.makeAttributedString(text, theme: .default)

        let narrow = TextLayoutEngine.layout(attributedString: attributed, width: 140)
        #expect(narrow.size.height > 0)
        #expect(narrow.lines.count >= 2)

        let wide = TextLayoutEngine.layout(attributedString: attributed, width: 900)
        #expect(wide.lines.count < narrow.lines.count)
    }

    @Test func layoutIsDeterministicForIdenticalInput() {
        let attributed = AttributedTextBuilder.makeAttributedString(
            .plain("Determinism check: identical input, identical geometry."),
            theme: .default
        )
        let first = TextLayoutEngine.layout(attributedString: attributed, width: 200)
        let second = TextLayoutEngine.layout(attributedString: attributed, width: 200)
        #expect(first.size == second.size)
        #expect(first.lines.count == second.lines.count)
    }

    @Test func linkRunsCarryDestinationAttribute() {
        let text = InlineText(runs: [
            InlineRun(text: "Open "),
            InlineRun(text: "the docs", linkDestination: "https://example.com/docs"),
        ])
        let attributed = AttributedTextBuilder.makeAttributedString(text, theme: .default)
        var found = false
        attributed.enumerateAttribute(
            CMKAttribute.linkDestination,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if let destination = value as? String, destination == "https://example.com/docs" {
                found = true
            }
        }
        #expect(found)
    }

    @Test func emptyTextYieldsZeroHeightAndNoLines() {
        let attributed = AttributedTextBuilder.makeAttributedString(.plain(""), theme: .default)
        let result = TextLayoutEngine.layout(attributedString: attributed, width: 300)
        #expect(result.size.height == 0)
        #expect(result.lines.isEmpty)
    }

    /// The per-run draw path (used when a line contains link runs) must paint
    /// link runs in the palette's link color and everything else in the text
    /// color — and the block must still expose LinkRegions for hit-testing.
    @Test func drawPaintsLinkRunsInLinkColor() throws {
        let text = InlineText(runs: [
            InlineRun(text: "Read "),
            InlineRun(text: "the docs", linkDestination: "https://example.com/docs"),
            InlineRun(text: " today"),
        ])
        let block = MarkdownBlock(
            id: BlockID(messageID: MessageID("draw-test"), birthOrder: 0),
            revision: .zero,
            content: .paragraph(text)
        )
        let result = BlockLayoutEngine.layout(
            block: block, width: 400, theme: .default, environment: RenderEnvironment()
        )
        #expect(!result.links.isEmpty) // regions survive the draw-path change

        let width = Int(result.size.width.rounded(.up))
        let height = Int(result.size.height.rounded(.up))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let palette = DrawPalette(
            text: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            rule: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            quoteBar: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            link: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        )
        result.draw(in: context, palette: palette)

        let data = try #require(context.data)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var sawLinkColor = false
        var sawTextColor = false
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let r = pixels[index]
            let g = pixels[index + 1]
            let b = pixels[index + 2]
            let a = pixels[index + 3]
            guard a > 200 else { continue }
            if r > 200 && g < 60 && b < 60 { sawLinkColor = true }
            if r < 60 && g < 60 && b < 60 { sawTextColor = true }
            if sawLinkColor && sawTextColor { break }
        }
        #expect(sawLinkColor)
        #expect(sawTextColor)
    }
}
