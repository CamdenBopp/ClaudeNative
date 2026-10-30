import Testing
@testable import ChatMarkdownCore

@Test func completeDocumentsDoNotNeedStreamingFinish() {
    let result = DocumentMarkdownParser.parse("# Note\n\n```swift\nlet value = 1")
    #expect(result.document.isComplete)
    #expect(result.document.blocks.count == 2)
    if case .codeBlock(let code) = result.document.blocks[1].content { #expect(code.isClosed) } else { Issue.record("Missing code block") }
    #expect(DocumentMarkdownParser.parse("").document.isComplete)
}

@Test func documentEditsCanReplaceAndDeleteEarlierContent() async {
    let session = MarkdownDocumentSession(id: .init("note"))
    let first = await session.replaceSource("# Title\n\nA paragraph.\n\nLast paragraph.")
    let second = await session.replaceSource("# Title\n\nInserted paragraph.\n\nA paragraph.\n\nLast paragraph.")
    #expect(first.document.blocks[1].id == second.document.blocks[2].id)
    #expect(first.document.blocks[2].id == second.document.blocks[3].id)
    let unchanged = await session.replaceSource(second.source)
    #expect(unchanged.document.revision == second.document.revision)
    let empty = await session.replaceSource("")
    #expect(empty.document.blocks.isEmpty)
    #expect(empty.document.isComplete)
}

@Test func documentSourceOffsetsRespectUnicodeAndFenceBoundaries() {
    let source = "😀 paragraph\n\n```\n# Not a heading\n```\n\n# Real heading"
    let parsed = DocumentMarkdownParser.parse(source)
    #expect(parsed.document.blocks.filter { $0.content.kind == .heading }.count == 1)
    let heading = parsed.document.blocks.last!
    let range = parsed.sourceRanges[heading.id]!
    let bytes = Array(source.utf8)
    #expect(String(decoding: bytes[range], as: UTF8.self) == "# Real heading")
}

@Test func repeatedDocumentBlocksReuseIdentityWithoutShiftingQueues() async throws {
    let count = 8_000
    let source = Array(repeating: "Repeated 😀 paragraph.\n\n", count: count).joined()
    let session = MarkdownDocumentSession(id: .init("repeated-note"))
    let first = await session.replaceSource(source)
    let workBefore = await session.identityMatchingBlockVisits
    let inserted = "# Inserted heading\n\n"
    let second = await session.replaceSource(inserted + source)
    #expect(second.document.blocks.dropFirst().map(\.id) == first.document.blocks.map(\.id))
    #expect(Set(second.document.blocks.map(\.id)).count == count + 1)
    let workAfter = await session.identityMatchingBlockVisits
    #expect(workAfter - workBefore == count * 2 + 1)
    for (before, after) in zip(first.document.blocks, second.document.blocks.dropFirst()) {
        #expect(before == after)
        let originalRange = try #require(first.sourceRanges[before.id])
        let currentRange = try #require(second.sourceRanges[after.id])
        #expect(currentRange == (originalRange.lowerBound + inserted.utf8.count)..<(originalRange.upperBound + inserted.utf8.count))
    }
    let unchanged = await session.replaceSource(second.source)
    #expect(unchanged.document.revision == second.document.revision)
    #expect(await session.identityMatchingBlockVisits == workAfter)
    // Keeping both snapshots alive must not allow the second update to alter
    // either the earlier identities or the source-to-block range mapping.
    #expect(first.document.blocks.count == count)
    #expect(first.source == source)
}

@Test func documentIdentityQueueRetainsFIFOStorageWhileConsumingDuplicates() {
    let count = 4_000
    var queue = BlockIdentityQueue()
    for index in 0..<count {
        queue.append(MarkdownBlock(id: .init(messageID: .init("queue"), birthOrder: index), revision: .zero, content: .paragraph(.plain("Repeated."))))
    }
    for index in 0..<count {
        #expect(queue.popFirst()?.id == .init(messageID: .init("queue"), birthOrder: index))
        #expect(queue.consumedCount == index + 1)
        // A cursor queue retains N slots throughout consumption. A shifting
        // array queue would shrink here and reintroduce quadratic movement.
        #expect(queue.storedCount == count)
    }
    #expect(queue.popFirst() == nil)
}

@Test func repeatedBlockDeletionAndNewContentKeepFIFOIdentityRule() async {
    let session = MarkdownDocumentSession(id: .init("repeat-edits"))
    let first = await session.replaceSource("Repeat.\n\nMiddle.\n\nRepeat.\n\nRepeat.")
    let second = await session.replaceSource("Repeat.\n\nRepeat.\n\nNew.")
    #expect(second.document.blocks[0].id == first.document.blocks[0].id)
    #expect(second.document.blocks[1].id == first.document.blocks[2].id)
    #expect(!first.document.blocks.map(\.id).contains(second.document.blocks[2].id))
    let third = await session.replaceSource("New.\n\nRepeat.\n\nRepeat.\n\nRepeat.")
    #expect(third.document.blocks[0].id == second.document.blocks[2].id)
    #expect(third.document.blocks[1].id == second.document.blocks[0].id)
    #expect(third.document.blocks[2].id == second.document.blocks[1].id)
    #expect(third.document.blocks[3].id != first.document.blocks[3].id)
}
