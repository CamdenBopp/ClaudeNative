import Testing
@testable import ChatMarkdownCore

/// Deterministic PRNG so failures reproduce from the reported seed.
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

/// The incremental pipeline (frozen prefix + tail parse + fast code path)
/// must be observationally identical to a full reparse after every append.
/// This differential test is the enforcement mechanism for every shortcut
/// the assembler takes.
struct DifferentialFuzzTests {
    private static let fragments: [String] = [
        "Hello world. ",
        "Some *emphasis",
        "* and more\n",
        "\n\n",
        "# Heading\n",
        "## Sub **head**\n",
        "- item a\n",
        "- item b\n\n",
        "1. one\n",
        "2. two\n\n",
        "> quoted line\n",
        "> more quote\n\n",
        "```swift\n",
        "let x = 1\n",
        "print(\"hi\")\n",
        "```\n",
        "~~~\nalt fence body\n~~~\n",
        "text with `code` span ",
        "[a link](https://example.com) ",
        "| a | b |\n",
        "|---|---|\n",
        "| 1 | 2 |\n\n",
        "***\n",
        "trailing words",
        "with dict[key]: value inside ",     // "]:"-lookalike inside prose
        "[ref]: https://ref.example.com\n",  // real definition → full-reparse mode
        "uses [the ref][ref] here. ",
        "    indented code line\n",
        "<div>\nhtml block\n</div>\n\n",
        "emoji ✅ and ünïcode. ",
        "```js\n",                                   // info-string line: opener, never a closer
        "````\nfour-tick fence with ``` inside\n````\n", // length matching
        "  ```\n",                                   // indented fence (container-ambiguous)
        "~~~~\n",
        "just ``` mid-sentence text ",               // inline triple-tick, not a fence line
        "CRLF line\r\nand another\r\n\r\n",          // carriage-return line endings
        "family 👩‍👩‍👧‍👦 emoji ",                     // ZWJ grapheme cluster
        "escaped \\*stars\\* and \\`tick\\` ",       // backslash escapes
        "<https://autolink.example> ",
        "<!-- html comment -->\n\n",
        "Setext\n====\n",
    ]

    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    func incrementalMatchesFullReparse(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let assembler = StreamingMessageAssembler(messageID: MessageID("fuzz-\(seed)"))
        var source = ""

        for step in 0..<60 {
            let fragment = Self.fragments.randomElement(using: &rng)!
            assembler.append(fragment)
            source += fragment

            let expected = StreamingMessageAssembler.referenceContents(source: source, isComplete: false)
            let actual = assembler.currentDocument.blocks.map(\.content)
            #expect(
                actual == expected,
                "divergence at seed \(seed) step \(step); source:\n\(source)"
            )
            if actual != expected { return } // one detailed failure beats sixty
        }

        assembler.finish()
        let expectedFinal = StreamingMessageAssembler.referenceContents(source: source, isComplete: true)
        #expect(assembler.currentDocument.blocks.map(\.content) == expectedFinal, "final divergence at seed \(seed)")
        #expect(assembler.currentDocument.isComplete)
    }

    @Test(arguments: [UInt64(100), 101, 102, 103])
    func identityInvariantsHoldUnderFuzz(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let assembler = StreamingMessageAssembler(messageID: MessageID("fuzz-id-\(seed)"))
        var everRemoved = Set<BlockID>()

        for _ in 0..<60 {
            let fragment = Self.fragments.randomElement(using: &rng)!
            let delta = assembler.append(fragment)

            // A removed ID must never come back.
            for id in delta.insertedBlockIDs {
                #expect(!everRemoved.contains(id), "seed \(seed): resurrected ID \(id)")
            }
            everRemoved.formUnion(delta.removedBlockIDs)

            // Inserted and updated sets are disjoint; live IDs are unique.
            #expect(Set(delta.insertedBlockIDs).isDisjoint(with: Set(delta.updatedBlockIDs)))
            let live = delta.document.blocks.map(\.id)
            #expect(Set(live).count == live.count, "seed \(seed): duplicate live IDs")
        }
    }
}
