import Testing
@testable import ClaudeNativeCore

/// The rotor's moves over a real conversation shape: the permission_allow
/// capture replayed through the live transcript.
struct TranscriptNavigationTests {
    func entries() throws -> [TranscriptEntry] {
        try FixtureReplayTests.replay("real_permission_allow", userText: "Create hello.txt").entries
    }

    @Test func toolCallsRotorVisitsOnlyToolRowsInOrder() throws {
        let entries = try entries()
        let first = try #require(TranscriptNavigation.step(in: entries, kind: .toolCalls, from: nil, direction: .next))
        #expect({ if case .tool = entries[first].kind { true } else { false } }())
        #expect(TranscriptNavigation.step(in: entries, kind: .toolCalls, from: first, direction: .next) == nil)
    }

    @Test func messagesRotorSkipsToolRows() throws {
        let entries = try entries()
        var index: Int? = nil
        var visited: [TranscriptEntry.Kind] = []
        while let next = TranscriptNavigation.step(in: entries, kind: .messages, from: index, direction: .next) {
            visited.append(entries[next].kind)
            index = next
        }
        #expect(!visited.isEmpty)
        #expect(visited.allSatisfy { $0 == .user || $0 == .assistant })
        #expect(visited.count == entries.count { $0.kind == .user || $0.kind == .assistant })
    }

    @Test func previousWalksBackwardAndStartsFromTheBottom() throws {
        let entries = try entries()
        let last = try #require(TranscriptNavigation.step(in: entries, kind: .messages, from: nil, direction: .previous))
        #expect(last == entries.lastIndex { $0.kind == .user || $0.kind == .assistant })
        let before = try #require(TranscriptNavigation.step(in: entries, kind: .messages, from: last, direction: .previous))
        #expect(before < last)
    }

    @Test func yourMessagesAndTypedFilter() throws {
        let entries = try entries()
        let mine = try #require(TranscriptNavigation.step(in: entries, kind: .yourMessages, from: nil, direction: .next))
        #expect(entries[mine].kind == .user)
        #expect(TranscriptNavigation.step(in: entries, kind: .messages, from: nil, direction: .next, filter: "HELLO.TXT") != nil)
        #expect(TranscriptNavigation.step(in: entries, kind: .messages, from: nil, direction: .next, filter: "no such words") == nil)
    }
}

struct MarkedNavigationTests {
    @Test func markedRotorVisitsOnlyMarkedEntriesInOrder() throws {
        let entries = try FixtureReplayTests.replay("real_permission_allow", userText: "Create hello.txt").entries
        let firstUser = try #require(entries.firstIndex { $0.kind == .user })
        let tool = try #require(entries.firstIndex { if case .tool = $0.kind { true } else { false } })
        let marked: Set<String> = [entries[firstUser].id, entries[tool].id]
        let first = TranscriptNavigation.step(in: entries, kind: .marked, from: nil, direction: .next, marked: marked)
        #expect(first == min(firstUser, tool))
        let second = TranscriptNavigation.step(in: entries, kind: .marked, from: first, direction: .next, marked: marked)
        #expect(second == max(firstUser, tool))
        #expect(TranscriptNavigation.step(in: entries, kind: .marked, from: second, direction: .next, marked: marked) == nil)
        #expect(TranscriptNavigation.step(in: entries, kind: .marked, from: nil, direction: .next) == nil)
    }
}

/// The Code Blocks rotor's moves over places in the conversation.
struct CodeBlockNavigationTests {
    typealias Position = TranscriptNavigation.Position
    /// Code blocks in rows 1 and 3: two in row 1, one in row 3.
    let targets = [Position(row: 1, block: 0), Position(row: 1, block: 2), Position(row: 3, block: 1)]

    @Test func stepsThroughCodeBlocksInOrderAndStopsAtEachEnd() {
        var visited: [Int] = []
        var current: Position?
        while let next = TranscriptNavigation.step(through: targets, from: current, direction: .next) {
            visited.append(next)
            current = targets[next]
        }
        #expect(visited == [0, 1, 2])
        #expect(TranscriptNavigation.step(through: targets, from: targets[0], direction: .previous) == nil)
        #expect(TranscriptNavigation.step(through: targets, from: nil, direction: .previous) == 2)
    }

    @Test func fromARowItStartsAtThatRowsOwnBlocks() {
        #expect(TranscriptNavigation.step(through: targets, from: Position(row: 1), direction: .next) == 0)
        #expect(TranscriptNavigation.step(through: targets, from: Position(row: 3), direction: .previous) == 1)
        // From a paragraph between two code blocks.
        #expect(TranscriptNavigation.step(through: targets, from: Position(row: 1, block: 1), direction: .next) == 1)
        #expect(TranscriptNavigation.step(through: targets, from: Position(row: 1, block: 1), direction: .previous) == 0)
        #expect(TranscriptNavigation.step(through: [], from: nil, direction: .next) == nil)
    }
}

/// The Go menu's Previous Message, Next Message and Go to Latest Message.
struct MessageMoveTests {
    func entries() throws -> [TranscriptEntry] {
        try FixtureReplayTests.replay("real_permission_allow", userText: "Create hello.txt").entries
    }

    func isMessage(_ entry: TranscriptEntry) -> Bool { entry.kind == .user || entry.kind == .assistant }

    @Test func nextWalksMessagesInOrderSkippingToolRowsAndStopsAtTheEnd() throws {
        let entries = try entries()
        var current: Int?
        var visited: [Int] = []
        while case .row(let next) = TranscriptNavigation.move(.next, in: entries, from: current) {
            visited.append(next)
            current = next
        }
        #expect(visited == entries.indices.filter { isMessage(entries[$0]) })
        #expect(visited.count >= 2)
        #expect(TranscriptNavigation.move(.next, in: entries, from: current) == .none(spoken: "Last message."))
    }

    /// Option-Command-Up and Down, as in the Claude app: your own
    /// messages only, skipping replies and tool rows, stopping at the ends.
    @Test func promptMovesVisitOnlyYourMessages() throws {
        let entries = [
            TranscriptEntry(id: "u1", kind: .user, text: "one"),
            TranscriptEntry(id: "a1", kind: .assistant, text: "reply"),
            TranscriptEntry(id: "t1", kind: .tool(name: "Bash", status: .succeeded), text: "ls"),
            TranscriptEntry(id: "u2", kind: .user, text: "two"),
            TranscriptEntry(id: "a2", kind: .assistant, text: "reply"),
        ]
        #expect(TranscriptNavigation.move(.previousPrompt, in: entries, from: 4) == .row(3))
        #expect(TranscriptNavigation.move(.previousPrompt, in: entries, from: 3) == .row(0))
        #expect(TranscriptNavigation.move(.previousPrompt, in: entries, from: 0) == .none(spoken: "First prompt."))
        #expect(TranscriptNavigation.move(.nextPrompt, in: entries, from: 1) == .row(3))
        #expect(TranscriptNavigation.move(.nextPrompt, in: entries, from: 3) == .none(spoken: "Last prompt."))
    }

    @Test func previousStopsAtTheFirstMessageWithoutWrapping() throws {
        let entries = try entries()
        let first = try #require(entries.firstIndex(where: isMessage))
        #expect(TranscriptNavigation.move(.previous, in: entries, from: first) == .none(spoken: "First message."))
        let last = try #require(entries.lastIndex(where: isMessage))
        guard case .row(let before) = TranscriptNavigation.move(.previous, in: entries, from: last) else {
            Issue.record("Previous from the last message went nowhere")
            return
        }
        #expect(before < last && isMessage(entries[before]))
    }

    @Test func fromAToolRowNextAndPreviousLandOnTheMessagesAroundIt() throws {
        let entries = try entries()
        let tool = try #require(entries.firstIndex { if case .tool = $0.kind { true } else { false } })
        #expect(TranscriptNavigation.move(.next, in: entries, from: tool)
            == entries[(tool + 1)...].firstIndex(where: isMessage).map(TranscriptNavigation.MessageMoveResult.row))
        #expect(TranscriptNavigation.move(.previous, in: entries, from: tool)
            == entries[..<tool].lastIndex(where: isMessage).map(TranscriptNavigation.MessageMoveResult.row))
    }

    @Test func latestIsTheLastMessageFromAnywhere() throws {
        let entries = try entries()
        let last = try #require(entries.lastIndex(where: isMessage))
        for current in [nil, 0, last] as [Int?] {
            #expect(TranscriptNavigation.move(.latest, in: entries, from: current) == .row(last))
        }
    }

    @Test func aConversationWithoutMessagesSaysSo() throws {
        let tools = try entries().filter { !isMessage($0) }
        #expect(!tools.isEmpty)
        for move in [TranscriptNavigation.MessageMove.previous, .next, .latest] {
            #expect(TranscriptNavigation.move(move, in: tools, from: nil) == .none(spoken: "No messages."))
        }
    }

    @Test func startsFromTheLastMessageMovedToOnlyWhileItIsOnScreen() {
        #expect(TranscriptNavigation.startingRow(lastVisited: 4, onScreen: 3..<6, topOfView: 3) == 4)
        #expect(TranscriptNavigation.startingRow(lastVisited: 1, onScreen: 3..<6, topOfView: 3) == 3)
        #expect(TranscriptNavigation.startingRow(lastVisited: nil, onScreen: 3..<6, topOfView: 3) == 3)
        #expect(TranscriptNavigation.startingRow(lastVisited: 6, onScreen: 3..<6, topOfView: 4) == 4)
        #expect(TranscriptNavigation.startingRow(lastVisited: nil, onScreen: 0..<0, topOfView: nil) == nil)
    }
}
