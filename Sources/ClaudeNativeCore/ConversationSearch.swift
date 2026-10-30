import Foundation

/// Filters the conversation list as the user types in its search field.
///
/// A conversation matches when every word of the query appears in its title
/// or its first prompt, ignoring case and accents: "cafe" finds "Café menu",
/// and "fence cost" finds "How much does a fence repair cost?". Words may
/// appear in either order and in different fields.
public enum ConversationSearch {
    /// How long typing has to pause before the result count is spoken, so
    /// VoiceOver says it once per search instead of once per keystroke.
    public static let announcementDelay: Duration = .milliseconds(500)

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// `text` with curly quotes made straight, so "don't" typed finds
    /// "don’t" written with smart quotes on, and the other way round;
    /// ignoring case and accents doesn't cover them.
    static func straightened<S: StringProtocol>(_ text: S) -> String {
        String(text.map { character -> Character in
            switch character {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}": "'"
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}": "\""
            default: character
            }
        })
    }

    /// The sessions that match `query`, in their original order. A query of
    /// only spaces matches everything.
    public static func filter(
        _ sessions: [SessionHistory.SessionSummary],
        query: String
    ) -> [SessionHistory.SessionSummary] {
        let words = terms(of: query)
        guard !words.isEmpty else { return sessions }
        return sessions.filter { matches($0, words: words) }
    }

    /// Whether one session matches `query`.
    public static func matches(_ session: SessionHistory.SessionSummary, query: String) -> Bool {
        matches(session, words: terms(of: query))
    }

    /// Whether the query has any words to search for.
    public static func isActive(_ query: String) -> Bool {
        !terms(of: query).isEmpty
    }

    /// What VoiceOver hears once typing settles: "3 conversations."
    public static func resultCountWording(_ count: Int) -> String {
        switch count {
        case 0: "No sessions."
        case 1: "1 session."
        default: "\(count) sessions."
        }
    }

    /// How well a matching session fits the query, best first: the whole
    /// query in its title, then every word in its title, then every word
    /// starting a word somewhere ("esc" in "Esc key"), then words found only
    /// inside other words ("esc" in "describe"). A palette that lists newest first put a
    /// long first prompt holding "esc", "test" and "a" above the session
    /// titled "Esc test A", and Return opened the wrong one.
    public static func relevance(_ session: SessionHistory.SessionSummary, query: String) -> Int {
        let phrase = straightened(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let (title, prompt) = (straightened(session.title), straightened(session.firstPrompt))
        if !phrase.isEmpty, title.range(of: phrase, options: options) != nil { return 3 }
        let words = terms(of: query)
        guard !words.isEmpty else { return 0 }
        if words.allSatisfy({ title.range(of: $0, options: options) != nil }) { return 2 }
        if words.allSatisfy({ startsAWord($0, in: title) || startsAWord($0, in: prompt) }) { return 1 }
        return 0
    }

    /// Whether `word` appears at the start of a word in `text`.
    private static func startsAWord(_ word: Substring, in text: String) -> Bool {
        var searched = text.startIndex..<text.endIndex
        while let found = text.range(of: word, options: options, range: searched) {
            if found.lowerBound == text.startIndex || !text[text.index(before: found.lowerBound)].isLetter && !text[text.index(before: found.lowerBound)].isNumber { return true }
            searched = found.upperBound..<text.endIndex
        }
        return false
    }

    /// The message shown in place of an empty list.
    public static func noMatchesWording(_ query: String) -> String {
        "No sessions match \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\"."
    }

    private static func terms(of query: String) -> [Substring] {
        straightened(query).split(whereSeparator: \.isWhitespace)
    }

    private static func matches(_ session: SessionHistory.SessionSummary, words: [Substring]) -> Bool {
        let (title, prompt) = (straightened(session.title), straightened(session.firstPrompt))
        return words.allSatisfy { word in
            title.range(of: word, options: options) != nil || prompt.range(of: word, options: options) != nil
        }
    }
}
