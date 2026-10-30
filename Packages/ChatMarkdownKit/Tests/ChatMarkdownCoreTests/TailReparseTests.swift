import Testing
@testable import ChatMarkdownCore

struct TailReparseTests {
    @Test func freezeAdvancesAcrossParagraphBoundaries() {
        let assembler = StreamingMessageAssembler(messageID: MessageID("t1"))
        assembler.append("Paragraph one is complete.\n\n")
        assembler.append("Paragraph two is also complete.\n\n")
        assembler.append("Paragraph three is still growing")

        // The first two paragraphs must be frozen out of the reparse window.
        #expect(assembler.frozenUTF8Length > 0)
        #expect(assembler.currentDocument.blocks.count == 3)
        #expect(assembler.currentDocument.blocks.map(\.content)
            == StreamingMessageAssembler.referenceContents(source: assembler.sourceText, isComplete: false))
    }

    @Test func frozenBlocksKeepIdentityAndNeverUpdate() throws {
        let assembler = StreamingMessageAssembler(messageID: MessageID("t2"))
        assembler.append("Stable paragraph.\n\n")
        let afterFirst = assembler.currentDocument
        try #require(afterFirst.blocks.count == 1)
        let firstID = afterFirst.blocks[0].id

        for index in 0..<20 {
            let delta = assembler.append("More text \(index). ")
            #expect(!delta.updatedBlockIDs.contains(firstID))
            #expect(!delta.removedBlockIDs.contains(firstID))
        }
        #expect(assembler.currentDocument.blocks[0].id == firstID)
    }

    @Test func openCodeBlockUsesFastPathAndStaysCorrect() throws {
        let assembler = StreamingMessageAssembler(messageID: MessageID("t3"))
        assembler.append("Example:\n\n```swift\n")
        let baselineParses = assembler.tailParseCount

        for index in 0..<50 {
            assembler.append("let value\(index) = \(index)\n")
        }
        // Every one of those 50 appends must have skipped the parser.
        #expect(assembler.tailParseCount == baselineParses)
        #expect(assembler.fastCodePathCount == 50)
        #expect(assembler.currentDocument.blocks.map(\.content)
            == StreamingMessageAssembler.referenceContents(source: assembler.sourceText, isComplete: false))

        let codeID = assembler.currentDocument.blocks[1].id
        assembler.append("```\n")
        let final = assembler.finish()
        #expect(final.document.blocks[1].id == codeID)
        guard case .codeBlock(let code) = final.document.blocks[1].content else {
            Issue.record("expected code block")
            return
        }
        #expect(code.isClosed)
        #expect(code.rawText.contains("let value49 = 49"))
    }

    @Test func fastPathHandlesChunksWithoutTrailingNewline() {
        let assembler = StreamingMessageAssembler(messageID: MessageID("t4"))
        assembler.append("```\n")
        assembler.append("partial line")   // no trailing newline
        assembler.append(" continues\n")
        assembler.append("next line\n")
        #expect(assembler.currentDocument.blocks.map(\.content)
            == StreamingMessageAssembler.referenceContents(source: assembler.sourceText, isComplete: false))
        guard case .codeBlock(let code) = assembler.currentDocument.blocks[0].content else {
            Issue.record("expected code block")
            return
        }
        #expect(code.rawText == "partial line continues\nnext line\n")
    }

    @Test func linkReferenceDefinitionTriggersFullReparse() throws {
        let assembler = StreamingMessageAssembler(messageID: MessageID("t5"))
        assembler.append("See [the docs][d] for details.\n\n")
        assembler.append("Unrelated paragraph.\n\n")
        #expect(assembler.frozenUTF8Length > 0)

        assembler.append("[d]: https://example.com/docs\n")
        // Freezing must be disabled: the definition rewrites block 0.
        #expect(assembler.frozenUTF8Length == 0)

        let final = assembler.finish()
        guard case .paragraph(let text) = final.document.blocks[0].content else {
            Issue.record("expected paragraph")
            return
        }
        #expect(text.runs.contains { $0.linkDestination == "https://example.com/docs" })
    }

    @Test func manyParagraphsKeepTailWindowSmall() {
        let assembler = StreamingMessageAssembler(messageID: MessageID("t6"))
        for index in 0..<100 {
            assembler.append("Paragraph number \(index) with some words.\n\n")
        }
        // The reparse window must not scale with the document: nearly all of
        // the source should be frozen.
        let tailLength = assembler.sourceText.utf8.count - assembler.frozenUTF8Length
        #expect(tailLength < 200)
        #expect(assembler.currentDocument.blocks.count == 100)
        #expect(assembler.currentDocument.blocks.map(\.content)
            == StreamingMessageAssembler.referenceContents(source: assembler.sourceText, isComplete: false))
    }
}
