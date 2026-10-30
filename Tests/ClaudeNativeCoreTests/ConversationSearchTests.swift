import Foundation
import Testing
@testable import ClaudeNativeCore

/// The conversation list's search, run over sessions listed from the saved
/// files in Tests/Fixtures/history, so titles and first prompts are the ones
/// the listing really produces.
struct ConversationSearchTests {
    /// Lists the fixtures as one project folder would, newest first:
    /// "Kitchen remodel" (first prompt "Help me price a kitchen remodel"),
    /// "Fence repair estimate" ("How much does a fence repair cost?"),
    /// "Legacy summary title" ("Old-format session prompt") and the untitled
    /// watering schedule.
    static func listedSessions() throws -> (TemporaryFolder, [SessionHistory.SessionSummary]) {
        let projects = try TemporaryFolder()
        let folder = projects.url.appending(path: "project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (age, name) in ["titled", "ai_titled", "summary_titled", "untitled"].enumerated() {
            let destination = folder.appending(path: "session-\(name).jsonl")
            // Dated by its records, as the listing dates a conversation.
            let text = try String(contentsOf: SessionHistoryTests.history.appending(path: "\(name).jsonl"), encoding: .utf8)
            try ProjectListTests.dated(text, age: Double(age) * 60).write(to: destination, atomically: true, encoding: .utf8)
        }
        return (projects, SessionHistory.listSessions(inProjectDirectory: folder))
    }

    static func titles(_ query: String) throws -> [String] {
        let (folder, sessions) = try Self.listedSessions()
        defer { _ = folder }
        return ConversationSearch.filter(sessions, query: query).map(\.title)
    }

    @Test func listingKeepsTheFirstPromptOnOneLine() throws {
        let (folder, sessions) = try Self.listedSessions()
        defer { _ = folder }
        #expect(sessions.map(\.firstPrompt).prefix(3) == [
            "Help me price a kitchen remodel",
            "How much does a fence repair cost?",
            "Old-format session prompt",
        ])
        #expect(sessions.allSatisfy { !$0.firstPrompt.contains("\n") })
    }

    @Test func emptyOrBlankQueryKeepsEveryConversationInOrder() throws {
        let all = try Self.titles("")
        #expect(all.count == 4)
        #expect(try Self.titles("   ") == all)
        #expect(!ConversationSearch.isActive("  "))
    }

    @Test func titleMatchIgnoresCase() throws {
        #expect(try Self.titles("KITCHEN") == ["Kitchen remodel"])
        #expect(try Self.titles("legacy") == ["Legacy summary title"])
    }

    @Test func firstPromptIsSearchedWhenTheTitleDoesNotHaveTheWord() throws {
        // "price" is only in the prompt; the title is "Kitchen remodel".
        #expect(try Self.titles("price") == ["Kitchen remodel"])
        #expect(try Self.titles("old-format") == ["Legacy summary title"])
    }

    @Test func everyWordMustMatchSomewhereInEitherOrder() throws {
        // "fence" is in the title, "cost" only in the prompt.
        #expect(try Self.titles("cost fence") == ["Fence repair estimate"])
        #expect(try Self.titles("fence kitchen") == [])
    }

    @Test func nothingMatchesAnUnrelatedQuery() throws {
        #expect(try Self.titles("submarine") == [])
    }

    @Test func accentsAreIgnoredBothWays() {
        let url = URL(fileURLWithPath: "/dev/null")
        let cafe = SessionHistory.SessionSummary(
            id: "a", title: "Café menu", lastModified: .distantPast, fileURL: url, firstPrompt: "Draft a crème brûlée recipe"
        )
        let plain = SessionHistory.SessionSummary(
            id: "b", title: "Resume tips", lastModified: .distantPast, fileURL: url
        )
        #expect(ConversationSearch.filter([cafe, plain], query: "cafe").map(\.id) == ["a"])
        #expect(ConversationSearch.filter([cafe, plain], query: "CREME brulee").map(\.id) == ["a"])
        #expect(ConversationSearch.filter([cafe, plain], query: "résumé").map(\.id) == ["b"])
    }

    /// A prompt typed with smart quotes on has curly apostrophes; a search
    /// typed with straight ones missed it ("don't" against "don’t").
    @Test func curlyAndStraightQuotesMatch() {
        let url = URL(fileURLWithPath: "/dev/null")
        let curly = SessionHistory.SessionSummary(
            id: "a", title: "Why don’t the tests run?", lastModified: .distantPast, fileURL: url, firstPrompt: "The “slow” suite"
        )
        let straight = SessionHistory.SessionSummary(id: "b", title: "Can't build", lastModified: .distantPast, fileURL: url)
        #expect(ConversationSearch.filter([curly, straight], query: "don't").map(\.id) == ["a"])
        #expect(ConversationSearch.filter([curly, straight], query: "\"slow\"").map(\.id) == ["a"])
        #expect(ConversationSearch.filter([curly, straight], query: "can’t").map(\.id) == ["b"])
        #expect(ConversationSearch.relevance(curly, query: "don't the") == 3)
    }

    @Test func wording() {
        #expect(ConversationSearch.resultCountWording(0) == "No sessions.")
        #expect(ConversationSearch.resultCountWording(1) == "1 session.")
        #expect(ConversationSearch.resultCountWording(3) == "3 sessions.")
        #expect(ConversationSearch.noMatchesWording(" submarine ") == "No sessions match \"submarine\".")
    }
}
