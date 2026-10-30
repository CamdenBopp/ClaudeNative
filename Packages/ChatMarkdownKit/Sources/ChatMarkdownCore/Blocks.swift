import Foundation

/// One top-level semantic unit of a message. The same block model drives
/// visual layout and the accessibility projection — there is no second parse.
public struct MarkdownBlock: Hashable, Sendable {
    public let id: BlockID
    public var revision: BlockRevision
    public var content: BlockContent

    public init(id: BlockID, revision: BlockRevision, content: BlockContent) {
        self.id = id
        self.revision = revision
        self.content = content
    }
}

/// Structural discriminator used by the streaming reconciler: a block that
/// keeps its kind across a reparse keeps its identity.
public enum BlockKind: Hashable, Sendable {
    case paragraph
    case heading
    case codeBlock
    case blockQuote
    case unorderedList
    case orderedList
    case table
    case thematicBreak
    case htmlBlock
}

public indirect enum BlockContent: Hashable, Sendable {
    case paragraph(InlineText)
    case heading(level: Int, text: InlineText)
    case codeBlock(CodeBlockContent)
    /// Nested children currently carry no independent BlockID; identity and
    /// caching happen at the top-level block. Revisit if per-item accessibility
    /// actions need addressable nested identity.
    case blockQuote([BlockContent])
    case unorderedList(items: [[BlockContent]])
    case orderedList(start: Int, items: [[BlockContent]])
    case table(TableContent)
    case thematicBreak
    /// Raw HTML is never interpreted or executed — it renders as literal text.
    case htmlBlock(literal: String)

    public var kind: BlockKind {
        switch self {
        case .paragraph: return .paragraph
        case .heading: return .heading
        case .codeBlock: return .codeBlock
        case .blockQuote: return .blockQuote
        case .unorderedList: return .unorderedList
        case .orderedList: return .orderedList
        case .table: return .table
        case .thematicBreak: return .thematicBreak
        case .htmlBlock: return .htmlBlock
        }
    }
}

public struct CodeBlockContent: Hashable, Sendable {
    /// The info string from the fence, e.g. "swift". Nil for indented blocks.
    public var languageHint: String?
    public var rawText: String
    /// False while the closing fence has not arrived in the stream. The code
    /// renderer uses this to keep the block in append mode and to report
    /// "still receiving" state to accessibility.
    public var isClosed: Bool

    public init(languageHint: String?, rawText: String, isClosed: Bool) {
        self.languageHint = languageHint
        self.rawText = rawText
        self.isClosed = isClosed
    }
}

public enum ColumnAlignment: Hashable, Sendable {
    case natural
    case left
    case center
    case right
}

public struct TableContent: Hashable, Sendable {
    public var columnAlignments: [ColumnAlignment]
    public var head: [InlineText]
    public var rows: [[InlineText]]

    public init(columnAlignments: [ColumnAlignment], head: [InlineText], rows: [[InlineText]]) {
        self.columnAlignments = columnAlignments
        self.head = head
        self.rows = rows
    }
}

/// Styled inline content as a flat run sequence — the unit that the attributed
/// string builder and the accessibility label generator both consume.
public struct InlineText: Hashable, Sendable {
    public var runs: [InlineRun]

    public init(runs: [InlineRun]) {
        self.runs = runs
    }

    public static func plain(_ text: String) -> InlineText {
        InlineText(runs: [InlineRun(text: text)])
    }

    public var plainText: String {
        runs.map(\.text).joined()
    }
}

public struct InlineRun: Hashable, Sendable {
    public struct Attributes: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let bold = Attributes(rawValue: 1 << 0)
        public static let italic = Attributes(rawValue: 1 << 1)
        public static let code = Attributes(rawValue: 1 << 2)
        public static let strikethrough = Attributes(rawValue: 1 << 3)
    }

    public var text: String
    public var attributes: Attributes
    /// Raw destination string, not URL: mid-stream destinations can be partial
    /// or invalid. Validation happens at activation time, never at parse time.
    public var linkDestination: String?
    public var image: ImageRef?

    public init(
        text: String,
        attributes: Attributes = [],
        linkDestination: String? = nil,
        image: ImageRef? = nil
    ) {
        self.text = text
        self.attributes = attributes
        self.linkDestination = linkDestination
        self.image = image
    }
}

/// Inline image reference. Rendering shows a placeholder until the attachment
/// pipeline resolves it; `altText` feeds both the placeholder and VoiceOver.
public struct ImageRef: Hashable, Sendable {
    public var source: String?
    public var altText: String

    public init(source: String?, altText: String) {
        self.source = source
        self.altText = altText
    }
}
