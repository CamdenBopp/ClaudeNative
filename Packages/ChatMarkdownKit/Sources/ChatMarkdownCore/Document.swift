import Foundation

/// Immutable snapshot of one message's parsed content. Snapshots are value
/// types and Sendable — this is what crosses the boundary between the
/// streaming assembler and background layout work.
public struct MarkdownDocument: Hashable, Sendable {
    public let messageID: MessageID
    public var revision: DocumentRevision
    public var blocks: [MarkdownBlock]
    /// False while tokens are still arriving.
    public var isComplete: Bool

    public init(
        messageID: MessageID,
        revision: DocumentRevision,
        blocks: [MarkdownBlock],
        isComplete: Bool
    ) {
        self.messageID = messageID
        self.revision = revision
        self.blocks = blocks
        self.isComplete = isComplete
    }

    public static func empty(messageID: MessageID) -> MarkdownDocument {
        MarkdownDocument(messageID: messageID, revision: .zero, blocks: [], isComplete: false)
    }
}

/// What changed between two document revisions. Consumers (layout scheduler,
/// UIKit layer, accessibility projection) invalidate only what is listed here —
/// an unchanged block never re-lays-out because of a streaming append.
public struct DocumentDelta: Sendable {
    public let document: MarkdownDocument
    public let insertedBlockIDs: [BlockID]
    public let updatedBlockIDs: [BlockID]
    public let removedBlockIDs: [BlockID]

    public init(
        document: MarkdownDocument,
        insertedBlockIDs: [BlockID],
        updatedBlockIDs: [BlockID],
        removedBlockIDs: [BlockID]
    ) {
        self.document = document
        self.insertedBlockIDs = insertedBlockIDs
        self.updatedBlockIDs = updatedBlockIDs
        self.removedBlockIDs = removedBlockIDs
    }

    public var isEmptyChange: Bool {
        insertedBlockIDs.isEmpty && updatedBlockIDs.isEmpty && removedBlockIDs.isEmpty
    }
}
