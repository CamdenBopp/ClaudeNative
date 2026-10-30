import Foundation

/// Saved conversations grouped by when they were last active, newest
/// group first, the way Notes and Mail divide a long list.
public enum ConversationGroups {
    public struct Group: Sendable, Equatable, Identifiable {
        public let title: String
        public let sessions: [SessionHistory.SessionSummary]
        public var id: String { title }
    }

    /// Days covered by "Previous 7 Days" and "Previous 30 Days", counted
    /// back from today.
    static let weekDays = 7
    static let monthDays = 30

    /// `sessions` should be newest first; each group keeps that order.
    public static func grouped(
        _ sessions: [SessionHistory.SessionSummary], now: Date = Date(), calendar: Calendar = .current
    ) -> [Group] {
        let today = calendar.startOfDay(for: now)
        var titles: [String] = []
        var members: [String: [SessionHistory.SessionSummary]] = [:]
        for session in sessions {
            let title = groupTitle(for: session.lastModified, today: today, calendar: calendar)
            if members[title] == nil { titles.append(title) }
            members[title, default: []].append(session)
        }
        return titles.map { Group(title: $0, sessions: members[$0] ?? []) }
    }

    static func groupTitle(for date: Date, today: Date, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: date)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch daysAgo {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case ..<weekDays: return "Previous 7 Days"
        case ..<monthDays: return "Previous 30 Days"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: today)
            return date.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
        }
    }
}
