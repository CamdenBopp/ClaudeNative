import Foundation

/// A complete document parse, independent of token streams and chat layout.
/// Source ranges are UTF-8 byte offsets into `source`, never rendered text.
public struct ParsedMarkdownDocument: Sendable {
    public let source: String
    public let document: MarkdownDocument
    public let sourceRanges: [BlockID: Range<Int>]
}

/// Notes can replace any part of their source, including deleting all of it.
/// Each result is complete at EOF (even with an unclosed Markdown fence).
/// No streaming assembler, bubble, sender, or append-only state is involved.
public enum DocumentMarkdownParser {
    public static func parse(_ source: String, id: MessageID = MessageID(UUID().uuidString), revision: DocumentRevision = .zero) -> ParsedMarkdownDocument {
        let parsed = CmarkDirectParser.parsedBlocks(from: source)
        var ranges: [BlockID: Range<Int>] = [:]
        var lineStarts = [0]
        for (offset, byte) in source.utf8.enumerated() where byte == 10 { lineStarts.append(offset + 1) }
        let length = source.utf8.count
        let blocks = parsed.enumerated().map { index, block in
            let blockID = BlockID(messageID: id, birthOrder: index)
            if let range = block.range {
                let startLine = range.lowerBound.line - 1
                let endLine = range.upperBound.line - 1
                if lineStarts.indices.contains(startLine), lineStarts.indices.contains(endLine) {
                    let start = min(length, lineStarts[startLine] + range.lowerBound.column - 1)
                    let end = min(length, lineStarts[endLine] + range.upperBound.column - 1)
                    ranges[blockID] = start..<max(start, end)
                }
            }
            return MarkdownBlock(id: blockID, revision: .zero, content: block.content)
        }
        return ParsedMarkdownDocument(source: source, document: .init(messageID: id, revision: revision, blocks: blocks, isComplete: true), sourceRanges: ranges)
    }
}

/// Full-source editing with stable identities for unchanged blocks. A middle
/// insertion does not invalidate the paragraphs following it. The actor owns
/// revision ordering; hosts should discard a result if their source changed.
public actor MarkdownDocumentSession {
    private let id: MessageID
    private var current: ParsedMarkdownDocument?
    private var nextBirth = 0
    /// Blocks visited while building/consuming identity queues. Internal so
    /// complexity tests can distinguish work from wall-clock noise.
    private(set) var identityMatchingBlockVisits = 0

    public init(id: MessageID) { self.id = id }

    public func replaceSource(_ source: String) -> ParsedMarkdownDocument {
        if let current, current.source == source { return current }
        let revision = current?.document.revision.next() ?? .zero
        let parsed = DocumentMarkdownParser.parse(source, id: id, revision: revision)
        var oldByContent: [BlockContent: BlockIdentityQueue] = [:]
        for block in current?.document.blocks ?? [] {
            identityMatchingBlockVisits += 1
            oldByContent[block.content, default: BlockIdentityQueue()].append(block)
        }
        var blocks: [MarkdownBlock] = []
        var ranges: [BlockID: Range<Int>] = [:]
        blocks.reserveCapacity(parsed.document.blocks.count)
        ranges.reserveCapacity(parsed.sourceRanges.count)
        for block in parsed.document.blocks {
            identityMatchingBlockVisits += 1
            let stable: MarkdownBlock
            if let match = oldByContent[block.content]?.popFirst() {
                stable = match
            } else {
                stable = MarkdownBlock(id: .init(messageID: id, birthOrder: nextBirth), revision: .zero, content: block.content)
                nextBirth += 1
            }
            blocks.append(stable)
            if let range = parsed.sourceRanges[block.id] { ranges[stable.id] = range }
        }
        let result = ParsedMarkdownDocument(source: source, document: .init(messageID: id, revision: revision, blocks: blocks, isComplete: true), sourceRanges: ranges)
        current = result
        return result
    }
}

/// Repeated blocks keep the same FIFO identity rule as distinct blocks, but
/// consuming a match advances a cursor instead of copying and shifting the
/// remaining array. A note with N identical paragraphs therefore makes N
/// queue reads, rather than moving N(N-1)/2 block values.
struct BlockIdentityQueue {
    private var blocks: [MarkdownBlock] = []
    private(set) var consumedCount = 0
    var storedCount: Int { blocks.count }

    mutating func append(_ block: MarkdownBlock) { blocks.append(block) }

    mutating func popFirst() -> MarkdownBlock? {
        guard consumedCount < blocks.count else { return nil }
        defer { consumedCount += 1 }
        return blocks[consumedCount]
    }
}
