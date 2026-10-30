import Testing
@testable import ChatMarkdownCore

/// Maximum-adversity chunking: every document is streamed one Unicode scalar
/// at a time, so every possible boundary is exercised — including between CR
/// and LF of a CRLF pair, inside emoji ZWJ sequences, between a backslash and
/// the character it escapes, and one character at a time through fence
/// markers, table delimiter rows, and reference definitions.
///
/// The invariant is the same as the random fuzzer's, applied exhaustively:
/// after every single append, the incremental document must equal a full
/// reparse of the accumulated source.
struct StreamingBoundaryTests {
    static let documents: [String] = [
        // Fences and inline styles.
        "Intro with **bold** and `code`.\n\n```swift\nlet x = 1\nprint(x)\n```\n\nTail paragraph.",
        // CRLF line endings throughout, including around a fence.
        "CRLF test\r\nSecond line\r\n\r\nNew para with [link](https://ex.com/a).\r\n\r\n```\r\ncode line\r\n```\r\ndone\r\n",
        // Grapheme clusters: ZWJ family, flag, skin tone.
        "Family: 👩‍👩‍👧‍👦 and flag 🇺🇸 and wave 👋🏽 mixed in.\n\n- item one\n- item two\n",
        // Escapes and setext headings.
        "Escapes: \\*not emphasis\\* and \\`not code\\`.\n\nTitle\n=====\n\nBody under the setext heading.\n",
        // Reference definition arriving after its use.
        "Ref use [docs][d] early on.\n\nMiddle paragraph here.\n\n[d]: https://example.com/ref\n\nAfter the definition.",
        // Table with alignment row, HTML comment, autolink.
        "| left | right |\n|:-----|------:|\n| 1 | 2 |\n\nAfter table <!-- a comment --> and <https://auto.link> done.\n",
        // Bracket opened many tokens before it closes; double-backtick code.
        "Open bracket [ spans\n\nseveral\n\nblocks before ] closes. Plus `` double`tick `` code span.\n",
        // Nested lists with continuation and indented code.
        "1. one\n   1. nested item\n      continued line\n2. two\n\n    indented code line\n\nclosing words.\n",
    ]

    @Test(arguments: Array(0..<8))
    func scalarBoundaryStreamingMatchesFullReparse(documentIndex: Int) {
        let source = Self.documents[documentIndex]
        let assembler = StreamingMessageAssembler(messageID: MessageID("scalar-\(documentIndex)"))
        var streamed = ""

        for scalar in source.unicodeScalars {
            let chunk = String(scalar)
            assembler.append(chunk)
            streamed += chunk
            let expected = StreamingMessageAssembler.referenceContents(source: streamed, isComplete: false)
            let actual = assembler.currentDocument.blocks.map(\.content)
            #expect(
                actual == expected,
                "document \(documentIndex) diverged after \(streamed.unicodeScalars.count) scalars; streamed:\n\(streamed.debugDescription)"
            )
            if actual != expected { return } // first divergence is the informative one
        }

        assembler.finish()
        let expectedFinal = StreamingMessageAssembler.referenceContents(source: source, isComplete: true)
        #expect(assembler.currentDocument.blocks.map(\.content) == expectedFinal)
        #expect(assembler.currentDocument.isComplete)
    }

    /// Identity invariants under scalar streaming: no resurrected IDs, no
    /// duplicate live IDs, inserted/updated disjoint — same rules the random
    /// fuzzer enforces, at every boundary.
    @Test(arguments: Array(0..<8))
    func scalarBoundaryIdentityInvariants(documentIndex: Int) {
        let source = Self.documents[documentIndex]
        let assembler = StreamingMessageAssembler(messageID: MessageID("scalar-id-\(documentIndex)"))
        var everRemoved = Set<BlockID>()

        for scalar in source.unicodeScalars {
            let delta = assembler.append(String(scalar))
            for id in delta.insertedBlockIDs {
                #expect(!everRemoved.contains(id), "resurrected ID in document \(documentIndex)")
            }
            everRemoved.formUnion(delta.removedBlockIDs)
            #expect(Set(delta.insertedBlockIDs).isDisjoint(with: Set(delta.updatedBlockIDs)))
            let live = delta.document.blocks.map(\.id)
            #expect(Set(live).count == live.count, "duplicate live IDs in document \(documentIndex)")
        }
    }
}
