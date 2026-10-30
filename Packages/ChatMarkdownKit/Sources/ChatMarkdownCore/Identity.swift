import Foundation

/// Stable identity of one chat message.
public struct MessageID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Monotonically increasing revision of a message's parsed document.
/// Background layout results are committed only if the revision they were
/// produced for is still the document's current revision.
public struct DocumentRevision: Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let zero = DocumentRevision(0)

    public func next() -> DocumentRevision {
        DocumentRevision(rawValue + 1)
    }

    public static func < (lhs: DocumentRevision, rhs: DocumentRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Identity of a block within a message.
///
/// `birthOrder` is assigned when the block first appears in the stream and is
/// never reused within the message, so identity does not depend on the block's
/// current index. A tail paragraph that keeps growing keeps its ID; a block
/// whose structural kind changes in place (tail paragraph becomes a fenced
/// code block) is a *different* block and gets a fresh ID.
public struct BlockID: Hashable, Sendable {
    public let messageID: MessageID
    public let birthOrder: Int

    public init(messageID: MessageID, birthOrder: Int) {
        self.messageID = messageID
        self.birthOrder = birthOrder
    }
}

/// Revision of a single block's content. Bumped whenever the block's semantic
/// content changes. Layout caches key off (BlockID, BlockRevision, environment),
/// so unchanged blocks keep their cached layout across document revisions.
public struct BlockRevision: Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let zero = BlockRevision(0)

    public func next() -> BlockRevision {
        BlockRevision(rawValue + 1)
    }

    public static func < (lhs: BlockRevision, rhs: BlockRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
