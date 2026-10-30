import Foundation
import Testing
@testable import ClaudeNativeCore

struct ConversationGroupsTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h)) ?? .distantPast
    }

    func session(_ id: String, _ when: Date) -> SessionHistory.SessionSummary {
        .init(id: id, title: id, lastModified: when, fileURL: URL(fileURLWithPath: "/dev/null"), firstPrompt: id)
    }

    @Test func groupsNewestFirstByDay() {
        let now = date(2026, 10, 23, 15)
        let sessions = [
            session("this morning", date(2026, 10, 23, 0)),
            session("last night", date(2026, 10, 22, 23)),
            session("monday", date(2026, 10, 19)),
            session("three weeks ago", date(2026, 10, 2)),
            session("august", date(2026, 8, 10)),
            session("last year", date(2025, 12, 31)),
        ]
        let groups = ConversationGroups.grouped(sessions, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "August", "December 2025"])
        #expect(groups.map { $0.sessions.map(\.id) } == [["this morning"], ["last night"], ["monday"], ["three weeks ago"], ["august"], ["last year"]])
    }

    @Test func keepsOrderInsideAGroupAndSkipsEmptyGroups() {
        let now = date(2026, 10, 23, 15)
        let sessions = [session("b", date(2026, 10, 23, 14)), session("a", date(2026, 10, 23, 9)), session("old", date(2026, 3, 1))]
        let groups = ConversationGroups.grouped(sessions, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "March"])
        #expect(groups[0].sessions.map(\.id) == ["b", "a"])
    }
}
