import Foundation

/// The 1-based line and column of a caret, as the editor's status line
/// says it.
public enum CaretPosition {
    static func isParagraphBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || character == "\r\n" || character == "\u{2029}"
    }

    /// `utf16Offset` is the caret's location in `text` (NSTextView's
    /// selected range). A line ends where NSString's paragraphRange, and so
    /// the editor's line-number gutter, ends one: "\n", "\r", "\r\n"
    /// (one Swift character that isn't "\n") and U+2029. A form feed or
    /// U+2028 doesn't, though Swift calls them newlines.
    public static func lineAndColumn(in text: String, utf16Offset: Int) -> (line: Int, column: Int) {
        let utf16 = text.utf16
        let clamped = min(max(utf16Offset, 0), utf16.count)
        let index = String.Index(utf16Offset: clamped, in: text)
        let before = text[..<index]
        let line = before.reduce(1) { isParagraphBreak($1) ? $0 + 1 : $0 }
        let lineStart = before.lastIndex(where: isParagraphBreak).map { before.index(after: $0) } ?? before.startIndex
        return (line, before[lineStart...].count + 1)
    }
}
