import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// The new-session screen's next steps, as the Claude app's: resume the
/// folder's latest session, carry on uncommitted work, then prompts.
@MainActor
struct NextStepTests {
    static let latest = SessionHistory.SessionSummary(
        id: "s1", title: "Fix the sidebar grouping so worktrees fold into their repository", lastModified: .now,
        fileURL: URL(fileURLWithPath: "/tmp/s1.jsonl")
    )

    @Test func stepsFollowTheFolder() {
        let both = EmptyConversation.steps(latest: Self.latest, hasChanges: true)
        #expect(both.map(\.title) == [
            "Resume \"Fix the sidebar grouping so worktrees\u{2026}\"",
            "Continue uncommitted work",
            "Explain this project",
        ])
        #expect(both.first?.spokenTitle == "Resume \"Fix the sidebar grouping so worktrees fold into their repository\"")
        let fresh = EmptyConversation.steps(latest: nil, hasChanges: false)
        #expect(fresh.map(\.title) == ["Explain this project", "Review uncommitted changes", "Find likely bugs"])
        let changesOnly = EmptyConversation.steps(latest: nil, hasChanges: true)
        #expect(changesOnly.map(\.title) == ["Continue uncommitted work", "Explain this project", "Find likely bugs"])
    }
}
