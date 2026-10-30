#if canImport(AppKit)
import AppKit
import ChatMarkdownCore
import ChatMarkdownAppKit
import Testing

@MainActor struct AppKitMarkdownRendererTests {
    @Test func documentAndBlockProjectionAgree() {
        let document = DocumentMarkdownParser.parse("# Heading **bold**\n\nA *word*, `code`, ~~strike~~ and [link](https://example.org).\n\n> quote\n\n- one\n- two\n\n7. ordered\n8. last\n\n```swift\nlet value = 1\n```\n\n| a | b |\n|---|---|\n| x | y |\n\n---\n\n<div>literal</div>").document
        let together = DocumentMarkdownRenderer.attributedString(for: document)
        let separately = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { separately.append(NSAttributedString(string: "\n")) }
            separately.append(DocumentMarkdownRenderer.attributedString(for: block))
        }
        #expect(together.isEqual(to: separately))
        #expect(together.string.contains("•  one"))
        #expect(together.string.contains("1.  ordered"))
        #expect(together.string.contains("a  |  b"))
        #expect(together.string.contains("<div>literal</div>"))
    }

    @Test func inlineTraitsAndLinkPolicySurviveProjection() throws {
        let text = InlineText(runs: [
            .init(text: "bold", attributes: .bold),
            .init(text: "italic", attributes: .italic),
            .init(text: "code", attributes: [.code, .bold]),
            .init(text: "strike", attributes: .strikethrough),
            .init(text: "web", linkDestination: "https://example.org"),
            .init(text: "unsafe", linkDestination: "javascript:alert(1)"),
            .init(text: "emoji 👩🏽‍💻 e\u{301}"),
        ])
        let rendered = AppKitMarkdownRenderer.attributedString(for: [.heading(level: 2, text: text)])
        func offset(_ substring: String) -> Int { (rendered.string as NSString).range(of: substring).location }
        let italic = try #require(rendered.attribute(.font, at: offset("italic"), effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: italic).contains([.boldFontMask, .italicFontMask]))
        let code = try #require(rendered.attribute(.font, at: offset("code"), effectiveRange: nil) as? NSFont)
        #expect(code.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(rendered.attribute(.backgroundColor, at: offset("code"), effectiveRange: nil) != nil)
        #expect(rendered.attribute(.strikethroughStyle, at: offset("strike"), effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(rendered.attribute(.link, at: offset("web"), effectiveRange: nil) as? URL == URL(string: "https://example.org"))
        #expect(rendered.attribute(.link, at: offset("unsafe"), effectiveRange: nil) == nil)
        #expect(rendered.attribute(.link, at: offset("bold"), effectiveRange: nil) == nil)
        #expect(rendered.attribute(.backgroundColor, at: offset("italic"), effectiveRange: nil) == nil)
        #expect(rendered.string == text.plainText)
    }

    @Test func nestedListAndQuoteIndentsRemainDistinct() throws {
        let blocks: [BlockContent] = [.unorderedList(items: [
            [.paragraph(.plain("outer")), .unorderedList(items: [[.paragraph(.plain("inner"))]])],
            [.blockQuote([.paragraph(.plain("quote"))])],
        ])]
        let rendered = AppKitMarkdownRenderer.attributedString(for: blocks)
        func paragraph(_ text: String) throws -> NSParagraphStyle {
            try #require(rendered.attribute(.paragraphStyle, at: (rendered.string as NSString).range(of: text).location, effectiveRange: nil) as? NSParagraphStyle)
        }
        let outer = try paragraph("outer"), inner = try paragraph("inner"), quote = try paragraph("quote")
        #expect(outer.firstLineHeadIndent == 0)
        #expect(outer.headIndent == 14)
        #expect(inner.firstLineHeadIndent == 14)
        #expect(inner.headIndent == 28)
        #expect(quote.headIndent == 26)
        #expect(rendered.attribute(.foregroundColor, at: (rendered.string as NSString).range(of: "quote").location, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
    }

    @Test func independentStylesDoNotSharePaletteOrParagraphMetrics() throws {
        let blocks: [BlockContent] = [.paragraph(.plain("same")), .paragraph(.plain("text"))]
        var first = MarkdownRenderStyle(), second = MarkdownRenderStyle()
        first.bodyColor = .red; first.blockSpacing = 21
        second.bodyColor = .blue; second.blockSpacing = 3
        let a = AppKitMarkdownRenderer.attributedString(for: blocks, style: first)
        let b = AppKitMarkdownRenderer.attributedString(for: blocks, style: second)
        #expect(a.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .red)
        #expect(b.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .blue)
        #expect((a.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing == 21)
        #expect((b.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing == 3)
    }

    @Test func rendererRespectsTheModelsOrderedListStart() {
        let rendered = AppKitMarkdownRenderer.attributedString(for: [.orderedList(start: 7, items: [[.paragraph(.plain("first"))], [.paragraph(.plain("second"))]])])
        #expect(rendered.string == "7.  first\n8.  second")
    }

    @Test func distinctLinksAndHeadingSizesDoNotShareAttributes() throws {
        let blocks: [BlockContent] = (1...6).map { level in
            .heading(level: level, text: .init(runs: [
                .init(text: "Heading \(level)", linkDestination: "https://example.org/\(level)"),
                .init(text: " plain"),
            ]))
        }
        var style = MarkdownRenderStyle()
        style.bodySize = 20
        let rendered = AppKitMarkdownRenderer.attributedString(for: blocks, style: style)
        for level in 1...6 {
            let offset = (rendered.string as NSString).range(of: "Heading \(level)").location
            let font = try #require(rendered.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
            #expect(font.pointSize == 20 * style.headingScales[level - 1])
            #expect(rendered.attribute(.link, at: offset, effectiveRange: nil) as? URL == URL(string: "https://example.org/\(level)"))
        }
    }

    /// Opt-in release benchmark; timings are diagnostic, never CI thresholds.
    @Test func measureAppKitProjectionCost() {
        guard ProcessInfo.processInfo.environment["MARKDOWN_PERF"] != nil else { return }
        for fixture in ["plain", "rich-repeated-links", "rich-unique-links"] {
          for count in [100, 1_000, 5_000] {
            let paragraph = BlockContent.paragraph(InlineText(runs: [
                .init(text: "Paragraph "), .init(text: "bold", attributes: .bold),
                .init(text: " and "), .init(text: "code", attributes: .code),
                .init(text: " with "), .init(text: "a link", linkDestination: "https://example.org"),
            ]))
            let blocks: [BlockContent]
            switch fixture {
            case "plain": blocks = Array(repeating: .paragraph(.plain("Plain paragraph without inline styling.")), count: count)
            case "rich-unique-links": blocks = (0..<count).map { index in
                .paragraph(.init(runs: [
                    .init(text: "Paragraph \(index) "), .init(text: "bold", attributes: .bold),
                    .init(text: " and "), .init(text: "code", attributes: .code),
                    .init(text: " with "), .init(text: "a link", linkDestination: "https://example.org/\(index)"),
                ]))
            }
            default: blocks = Array(repeating: paragraph, count: count)
            }
            _ = AppKitMarkdownRenderer.attributedString(for: blocks)
            var samples: [Double] = []
            var length = 0
            for _ in 0..<7 {
                let start = ContinuousClock.now
                autoreleasepool { length = AppKitMarkdownRenderer.attributedString(for: blocks).length }
                let elapsed = start.duration(to: .now).components
                samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            }
            samples.sort()
            print("PERF AppKit projection \(fixture): \(count) paragraphs median \(samples[3]) ms, \(length) UTF16 units")
            #expect(length > count)
          }
        }
    }

    /// Neon projects one block per SwiftUI row. Keep that call pattern in the
    /// benchmark alongside the whole-message projection other hosts use.
    @Test func measureIndividualBlockProjectionCost() {
        guard ProcessInfo.processInfo.environment["MARKDOWN_PERF"] != nil else { return }
        let blocks = (0..<5_000).map { index in
            BlockContent.paragraph(.init(runs: [
                .init(text: "Paragraph \(index) "), .init(text: "bold", attributes: .bold),
                .init(text: " and "), .init(text: "code", attributes: .code),
                .init(text: " with "), .init(text: "a link", linkDestination: "https://example.org/\(index)"),
            ]))
        }
        var samples: [Double] = []
        var length = 0
        for _ in 0..<7 {
            let start = ContinuousClock.now
            autoreleasepool {
                length = blocks.reduce(0) { $0 + AppKitMarkdownRenderer.attributedString(for: [$1]).length }
            }
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        samples.sort()
        print("PERF AppKit individual rich blocks: 5000 blocks median \(samples[3]) ms, \(length) UTF16 units")
        #expect(length > blocks.count)
    }
}
#endif
