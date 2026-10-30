import Foundation

/// Moving through a conversation by kind of row, as VoiceOver's rotor does.
public enum TranscriptNavigation {
    public enum Kind: String, CaseIterable, Sendable {
        case messages = "Messages"
        case yourMessages = "Your Messages"
        case toolCalls = "Tool Calls"
        /// Messages the user marked to come back to. VoiceOver's own hot
        /// spots remember a screen position, so they lose a message once it
        /// scrolls away; marks follow the message itself.
        case marked = "Marked Messages"

        public func includes(_ entry: TranscriptEntry, marked: Set<String> = []) -> Bool {
            if self == .marked { return marked.contains(entry.id) }
            return switch (self, entry.kind) {
            case (.messages, .user), (.messages, .assistant): true
            case (.yourMessages, .user): true
            case (.toolCalls, .tool): true
            default: false
            }
        }
    }

    public enum Direction: Sendable {
        case next
        case previous
    }

    /// The name of the rotor that moves between code blocks in replies.
    public static let codeBlocksRotor = "Code Blocks"

    /// A place in the conversation: a row, or one block inside a row. A row
    /// comes before its own blocks.
    public struct Position: Comparable, Hashable, Sendable {
        public let row: Int
        /// The block's index in its row; nil for the row itself.
        public let block: Int?
        /// An item's index inside its block (a list item, a table row, or a
        /// link inside one); nil for the block itself.
        public let item: Int?

        public init(row: Int, block: Int? = nil, item: Int? = nil) {
            self.row = row
            self.block = block
            self.item = item
        }

        public static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.row, lhs.block ?? -1, lhs.item ?? -1) < (rhs.row, rhs.block ?? -1, rhs.item ?? -1)
        }
    }

    /// The index in `targets` (in conversation order) of the next or
    /// previous one after or before `current`. With no current place it
    /// starts from the top (next) or bottom (previous). Nil past the end:
    /// a rotor that wrapped around would wedge VoiceOver.
    public static func step(through targets: [Position], from current: Position?, direction: Direction) -> Int? {
        switch direction {
        case .next:
            guard let current else { return targets.indices.first }
            return targets.firstIndex { $0 > current }
        case .previous:
            guard let current else { return targets.indices.last }
            return targets.lastIndex { $0 < current }
        }
    }

    /// The index of the next or previous entry of `kind` after or before
    /// `current`, among entries containing `filter` (any case). With no
    /// current entry it starts from the top (next) or bottom (previous).
    /// Nil at the end of the list: VoiceOver says there's nothing more
    /// rather than wrapping around.
    public static func step(
        in entries: [TranscriptEntry],
        kind: Kind,
        from current: Int?,
        direction: Direction,
        filter: String = "",
        marked: Set<String> = []
    ) -> Int? {
        let matches = entries.indices.filter { index in
            kind.includes(entries[index], marked: marked)
                && (filter.isEmpty || entries[index].text.localizedCaseInsensitiveContains(filter))
        }
        switch direction {
        case .next:
            guard let current else { return matches.first }
            return matches.first { $0 > current }
        case .previous:
            guard let current else { return matches.last }
            return matches.last { $0 < current }
        }
    }

    /// The Go menu's moves through the conversation's messages.
    public enum MessageMove: Sendable {
        case previous
        case next
        case latest
        /// Your own messages only, as the Claude app's Option-Command-Up
        /// and Down jump between prompts.
        case previousPrompt
        case nextPrompt
    }

    /// Where a Go menu move lands: a row, or nowhere, with what to say.
    public enum MessageMoveResult: Equatable, Sendable {
        case row(Int)
        case none(spoken: String)
    }

    /// The row Previous Message and Next Message count from: the one last
    /// moved to while any of it is still on screen, otherwise the one at
    /// the top of the view. Scrolling away from the last one moved to
    /// starts over from what's in view, so a move never jumps back to a
    /// message the user has left behind.
    public static func startingRow(lastVisited: Int?, onScreen: Range<Int>, topOfView: Int?) -> Int? {
        if let lastVisited, onScreen.contains(lastVisited) { return lastVisited }
        return topOfView
    }

    /// The message row a Go menu move lands on, among your messages and
    /// Claude's replies. At either end it stays put and says so rather
    /// than wrapping, as the rotors do.
    public static func move(_ move: MessageMove, in entries: [TranscriptEntry], from current: Int?) -> MessageMoveResult {
        guard entries.contains(where: { Kind.messages.includes($0) }) else { return .none(spoken: "No messages.") }
        switch move {
        case .latest:
            return step(in: entries, kind: .messages, from: nil, direction: .previous).map(MessageMoveResult.row)
                ?? .none(spoken: "No messages.")
        case .previous:
            return step(in: entries, kind: .messages, from: current, direction: .previous).map(MessageMoveResult.row)
                ?? .none(spoken: "First message.")
        case .next:
            return step(in: entries, kind: .messages, from: current, direction: .next).map(MessageMoveResult.row)
                ?? .none(spoken: "Last message.")
        case .previousPrompt:
            return step(in: entries, kind: .yourMessages, from: current, direction: .previous).map(MessageMoveResult.row)
                ?? .none(spoken: "First prompt.")
        case .nextPrompt:
            return step(in: entries, kind: .yourMessages, from: current, direction: .next).map(MessageMoveResult.row)
                ?? .none(spoken: "Last prompt.")
        }
    }
}
