import Testing
@testable import ChatMarkdownCore

struct StreamingAssemblerTests {
    @Test func tailParagraphKeepsIdentityAcrossAppends() throws {
        let assembler = StreamingMessageAssembler(messageID: MessageID("m1"))

        let first = assembler.append("Hello")
        try #require(first.document.blocks.count == 1)
        let id = first.document.blocks[0].id
        #expect(first.insertedBlockIDs == [id])
        #expect(first.updatedBlockIDs.isEmpty)

        let second = assembler.append(" world, this is a streamed paragraph")
        try #require(second.document.blocks.count == 1)
        #expect(second.document.blocks[0].id == id)
        #expect(second.updatedBlockIDs == [id])
        #expect(second.insertedBlockIDs.isEmpty)
        #expect(second.document.blocks[0].content
            == .paragraph(.plain("Hello world, this is a streamed paragraph")))
        #expect(second.document.revision > first.document.revision)
    }

    @Test func blankLineStartsNewBlockWithoutTouchingEarlierBlocks() throws {
        let assembler = StreamingMessageAssembler(messageID: MessageID("m2"))

        let first = assembler.append("First paragraph.")
        try #require(first.document.blocks.count == 1)
        let firstID = first.document.blocks[0].id

        let second = assembler.append("\n\nSecond paragraph begins")
        try #require(second.document.blocks.count == 2)
        #expect(second.document.blocks[0].id == firstID)
        // The finished first paragraph must not be marked updated by an
        // append that only grows the tail.
        #expect(second.updatedBlockIDs.isEmpty)
        #expect(second.insertedBlockIDs == [second.document.blocks[1].id])
        #expect(second.document.blocks[1].id != firstID)
    }

    @Test func openingFenceStreamsAsOpenCodeBlockThenCloses() throws {
        let assembler = StreamingMessageAssembler(messageID: MessageID("m3"))

        assembler.append("Look:\n\n```swift\n")
        let streaming = assembler.append("let x = 1\n")
        try #require(streaming.document.blocks.count == 2)
        let codeID = streaming.document.blocks[1].id
        guard case .codeBlock(let open) = streaming.document.blocks[1].content else {
            Issue.record("expected a code block, got \(streaming.document.blocks[1].content)")
            return
        }
        #expect(open.isClosed == false)
        #expect(open.languageHint == "swift")
        #expect(open.rawText.contains("let x = 1"))

        assembler.append("```\n")
        let final = assembler.finish()
        try #require(final.document.blocks.count == 2)
        #expect(final.document.blocks[1].id == codeID)
        guard case .codeBlock(let closed) = final.document.blocks[1].content else {
            Issue.record("expected a code block after close")
            return
        }
        #expect(closed.isClosed)
        #expect(final.document.isComplete)
    }

    @Test func unchangedAppendEmitsEmptyDeltaForPriorBlocks() throws {
        let assembler = StreamingMessageAssembler(messageID: MessageID("m4"))
        assembler.append("# Title\n\nBody text here.\n\n")
        let before = assembler.currentDocument
        try #require(before.blocks.count == 2)

        // Appending a fresh block leaves the heading and paragraph untouched.
        let delta = assembler.append("- item one\n")
        #expect(delta.updatedBlockIDs.isEmpty)
        #expect(delta.removedBlockIDs.isEmpty)
        #expect(delta.insertedBlockIDs.count == 1)
        #expect(delta.document.blocks[0] == before.blocks[0])
        #expect(delta.document.blocks[1] == before.blocks[1])
    }

    @Test func inlineStylesConvert() throws {
        let assembler = StreamingMessageAssembler(messageID: MessageID("m5"))
        let delta = assembler.append(
            "This is **bold** and `code` and [a link](https://example.com)."
        )
        try #require(delta.document.blocks.count == 1)
        guard case .paragraph(let text) = delta.document.blocks[0].content else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(text.runs.contains { $0.text == "bold" && $0.attributes.contains(.bold) })
        #expect(text.runs.contains { $0.text == "code" && $0.attributes.contains(.code) })
        #expect(text.runs.contains {
            $0.text == "a link" && $0.linkDestination == "https://example.com"
        })
        #expect(text.plainText == "This is bold and code and a link.")
    }

    @Test func htmlIsKeptAsLiteralNeverInterpreted() throws {
        let assembler = StreamingMessageAssembler(messageID: MessageID("m6"))
        let delta = assembler.finishAppending("<script>alert(1)</script>\n")
        try #require(delta.document.blocks.count == 1)
        guard case .htmlBlock(let literal) = delta.document.blocks[0].content else {
            Issue.record("expected an html literal block")
            return
        }
        #expect(literal.contains("<script>"))
    }
}

private extension StreamingMessageAssembler {
    func finishAppending(_ text: String) -> DocumentDelta {
        append(text)
        return finish()
    }
}
