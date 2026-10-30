import Foundation

/// The words VoiceOver says for the parts of a Claude reply. A reply is a
/// group named "Claude" holding one element per Markdown block; these are
/// the names of the blocks that need more than their own text.
public enum ReplyBlockWording {
    /// "Swift code, 3 lines", "Code, 1 line", or with ", still receiving"
    /// while the block's closing fence hasn't arrived. `code` is the block's
    /// text without its fences.
    public static func codeLabel(fenceInfo: String?, code: String, isReceiving: Bool) -> String {
        let kind = languageName(fenceInfo: fenceInfo).map { "\($0) code" } ?? "Code"
        var parts = [kind]
        let lines = lineCount(code)
        if lines > 0 { parts.append(lines == 1 ? "1 line" : "\(lines) lines") }
        if isReceiving { parts.append("still receiving") }
        return parts.joined(separator: ", ")
    }

    /// How many lines `code` has. A final newline ends the last line rather
    /// than starting another.
    public static func lineCount(_ code: String) -> Int {
        guard !code.isEmpty else { return 0 }
        let newlines = code.reduce(0) { $1.isNewline ? $0 + 1 : $0 }
        return code.last?.isNewline == true ? newlines : newlines + 1
    }

    /// A fence's language as it is spoken: "swift" is "Swift", "js" is
    /// "JavaScript". A language this doesn't know is said as written; no
    /// fence, or an empty one, has none.
    public static func languageName(fenceInfo: String?) -> String? {
        let word = (fenceInfo ?? "")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "{" || $0 == "}" })
            .first
            .map { String($0.drop(while: { $0 == "." })) }
        guard let word, !word.isEmpty else { return nil }
        return spokenLanguages[word.lowercased()] ?? word
    }

    /// Fence words and how they're said. Kept to languages Claude writes
    /// often; anything else is read as written.
    private static let spokenLanguages: [String: String] = {
        let names: [(String, [String])] = [
            ("Swift", ["swift"]),
            ("Python", ["python", "py", "python3"]),
            ("JavaScript", ["javascript", "js", "jsx", "mjs", "cjs", "node"]),
            ("TypeScript", ["typescript", "ts", "tsx"]),
            ("JSON", ["json", "jsonc", "json5", "jsonl"]),
            ("Shell", ["bash", "sh", "zsh", "shell", "console", "ksh"]),
            ("Markdown", ["markdown", "md"]),
            ("HTML", ["html", "htm", "xhtml"]),
            ("CSS", ["css"]),
            ("C", ["c", "h"]),
            ("C++", ["cpp", "c++", "cc", "cxx", "hpp"]),
            ("Objective-C", ["objc", "objective-c", "m"]),
            ("Go", ["go", "golang"]),
            ("Rust", ["rust", "rs"]),
            ("Ruby", ["ruby", "rb"]),
            ("Java", ["java"]),
            ("Kotlin", ["kotlin", "kt"]),
            ("SQL", ["sql"]),
            ("YAML", ["yaml", "yml"]),
            ("TOML", ["toml"]),
            ("XML", ["xml", "plist"]),
            ("Diff", ["diff", "patch"]),
            ("Plain text", ["text", "txt", "plaintext"]),
        ]
        var table: [String: String] = [:]
        for (name, words) in names {
            for word in words { table[word] = name }
        }
        return table
    }()

    /// A list item: its text, after its number in a numbered list. A bullet
    /// isn't said, since VoiceOver already says it's in a list.
    public static func listItem(_ text: String, number: Int?) -> String {
        guard let number else { return text }
        return "\(number). \(text)"
    }

    /// A table's row, counting the header row as row 1: "Row 2: a, b".
    public static func tableRow(_ row: Int, cells: [String]) -> String {
        "Row \(row): \(cells.joined(separator: ", "))"
    }

    /// What a table's group is called: "Table, 3 rows".
    public static func tableLabel(rows: Int) -> String {
        rows == 1 ? "Table, 1 row" : "Table, \(rows) rows"
    }

    /// Text as one line: runs of spaces and line breaks become one space.
    public static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
