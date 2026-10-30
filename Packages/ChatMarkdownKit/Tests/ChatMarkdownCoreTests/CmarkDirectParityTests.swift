import Testing
@testable import ChatMarkdownCore

/// `CmarkDirectParser` must produce the exact same block model as the
/// swift-markdown-backed `MarkdownConverter` (the oracle). These assert
/// `BlockContent` equality over a vocabulary corpus and fuzzed documents; any
/// divergence fails, so the fast path can never silently render differently
/// from the reference parser.
struct CmarkDirectParityTests {
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static let corpus: [String] = [
        "# Title\n\nA paragraph with **bold**, *italic*, `code`, ~~struck~~ and a [link](https://x.example).\n",
        "## H2\n### H3\n\nSoft\nbreak and a hard  \nbreak.\n",
        "```swift\nlet x = 1\nprint(x)\n```\n\nafter\n",
        "```\nno language fence\n```\n",
        "    indented code\n    second line\n",
        "> a quote\n> continued\n>\n> second paragraph\n",
        "- one\n- two\n  - nested a\n  - nested b\n- three\n",
        "1. first\n2. second\n   1. inner\n3. third\n",
        "| Left | Center | Right |\n|:---|:---:|---:|\n| a | b | c |\n| d | e | f |\n",
        "***\n\nafter break\n",
        "<div class=\"x\">\nraw html block\n</div>\n",
        "text with inline <span>html</span> and an ![alt text](https://img.example/a.png) image.\n",
        "nested **bold *and italic* together** here.\n",
        "a [link with **bold** inside](https://y.example) and `code`.\n",
        "paragraph one\n\nparagraph two\n\nparagraph three\n",
        "trailing text with no newline",
        "emoji ✅, ünïcode, and a family 👩‍👩‍👧‍👦 cluster.\n",
        "escaped \\*stars\\* and \\`ticks\\` stay literal.\n",
        "",
        "\n\n\n",
    ]

    @Test func directParserMatchesOracleOnCorpus() {
        for (index, source) in Self.corpus.enumerated() {
            let oracle = MarkdownConverter.parsedBlocks(from: source).map(\.content)
            let direct = CmarkDirectParser.parsedBlocks(from: source).map(\.content)
            #expect(direct == oracle, "corpus[\(index)] diverged from swift-markdown:\n\(source)")
        }
    }

    @Test func longSoftBreakParagraphCoalescesWithoutChangingOracleSemantics() {
        let lines = (0..<10_000).map { "Line \($0) has Unicode café 😀." }
        let source = lines.joined(separator: "\n")
        let direct = CmarkDirectParser.parsedBlocks(from: source).map(\.content)
        #expect(direct == MarkdownConverter.blocks(from: source))
        #expect(direct == [.paragraph(.plain(lines.joined(separator: " ")))])
    }

    @Test func coalescingPreservesAttributesLinksAndImageBoundaries() {
        let boldLines = Array(repeating: "bold café", count: 1_000).joined(separator: "\n")
        let linkedLines = Array(repeating: "linked 😀", count: 1_000).joined(separator: "\n")
        let source = "**\(boldLines)** [\(linkedLines)](https://example.com) ![a](a.png)![b](b.png) after"
        let direct = CmarkDirectParser.parsedBlocks(from: source).map(\.content)
        #expect(direct == MarkdownConverter.blocks(from: source))
        guard case .some(.paragraph(let text)) = direct.first else { Issue.record("Expected paragraph"); return }
        #expect(text.runs.filter { $0.attributes.contains(.bold) }.count == 1)
        #expect(text.runs.filter { $0.linkDestination == "https://example.com" }.count == 1)
        #expect(text.runs.compactMap(\.image).map(\.altText) == ["a", "b"])
    }

    private static let fragments: [String] = [
        "Hello world. ", "Some *emphasis", "* and more\n", "\n\n", "# Heading\n",
        "## Sub **head**\n", "- item a\n", "- item b\n\n", "1. one\n", "2. two\n\n",
        "> quoted line\n", "> more quote\n\n", "```swift\n", "let x = 1\n", "```\n",
        "text with `code` span ", "[a link](https://example.com) ", "| a | b |\n",
        "|---|---|\n", "| 1 | 2 |\n\n", "***\n", "~~struck~~ ", "![img](https://i.example/x.png) ",
        "<div>\nhtml\n</div>\n\n", "    indented\n", "trailing words",
    ]

    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
    func directParserMatchesOracleUnderFuzz(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<50 {
            let count = Int.random(in: 1...24, using: &rng)
            var source = ""
            for _ in 0..<count { source += Self.fragments.randomElement(using: &rng)! }
            let oracle = MarkdownConverter.parsedBlocks(from: source).map(\.content)
            let direct = CmarkDirectParser.parsedBlocks(from: source).map(\.content)
            #expect(direct == oracle, "seed \(seed) diverged from swift-markdown:\n---\n\(source)\n---")
        }
    }
}
