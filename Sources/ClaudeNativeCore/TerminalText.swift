import Foundation

/// Turns what a shell writes to its terminal into text to read: escape
/// sequences (colors, cursor moves, titles) removed, a carriage return
/// that rewrites a line (a progress bar) keeping only the last version,
/// and backspaces applied. The terminal panel is line-based, so screen
/// drawing programs aren't rendered, only their text.
public struct TerminalText: Sendable {
    /// The finished lines and the line being written.
    public private(set) var text = ""
    private var line = ""
    private var pending = ""
    /// A carriage return not yet acted on: it rewrites the line only if
    /// text follows, so zsh's "\r\r\n" after a command ends the line
    /// instead of erasing the prompt and command first.
    private var returnPending = false

    /// The most text kept; older lines go first.
    public static let maxLength = 200_000
    /// Characters dropped from the front to stay under `maxLength`, so a
    /// position in everything written can be found in `shown`.
    public private(set) var droppedCount = 0

    public init() {}

    public var shown: String { text + line }

    /// Where the output ends, counted from the first character ever
    /// written; it stays meaningful after the cap drops old lines.
    public var endPosition: Int { droppedCount + shown.count }

    /// What's been written since `position` (an earlier `endPosition`), and
    /// the shown text before it. Counted from the front of `shown` instead,
    /// a position pointed past new output once old lines were dropped.
    public func since(_ position: Int) -> (new: String, before: String) {
        let shown = shown
        let offset = min(max(0, position - droppedCount), shown.count)
        return (String(shown.suffix(shown.count - offset)), String(shown.prefix(offset)))
    }

    public mutating func append(_ chunk: String) {
        var input = pending + chunk
        pending = ""
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            switch character {
            case "\u{1B}":
                guard let end = Self.endOfEscape(in: input, from: index) else {
                    // Split across reads: kept for the next chunk.
                    pending = String(input[index...])
                    index = input.endIndex
                    continue
                }
                index = end
                continue
            case "\r\n", "\n":
                returnPending = false
                text += Self.trimmed(line) + "\n"
                line = ""
            case "\r":
                returnPending = true
            case "\u{08}":
                if !line.isEmpty { line.removeLast() }
            case "\u{07}":
                break
            default:
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20, character != "\t" { break }
                if returnPending {
                    line = ""
                    returnPending = false
                }
                line.append(character)
            }
            index = input.index(after: index)
        }
        input = ""
        if text.count > Self.maxLength {
            let excess = text.count - Self.maxLength
            let cut = text.index(text.startIndex, offsetBy: excess)
            let lineStart = text[cut...].firstIndex(of: "\n").map { text.index(after: $0) } ?? cut
            droppedCount += text.distance(from: text.startIndex, to: lineStart)
            text.removeSubrange(text.startIndex..<lineStart)
        }
    }

    /// A line without the spaces a prompt pads it with.
    static func trimmed(_ line: String) -> String {
        var line = line
        while line.last == " " { line.removeLast() }
        return line
    }

    /// An escape string longer than this with no end is dropped, so a stray
    /// one can't hold back the rest of the output.
    static let maxEscapeLength = 4096

    /// Where an escape sequence starting at `start` ends (just past it), or
    /// nil when the input ends inside it.
    static func endOfEscape(in input: String, from start: String.Index) -> String.Index? {
        var index = input.index(after: start)
        guard index < input.endIndex else { return nil }
        switch input[index] {
        case "[":
            // CSI: parameters, then one final byte from @ to ~.
            index = input.index(after: index)
            while index < input.endIndex {
                if let value = input[index].unicodeScalars.first?.value, (0x40...0x7E).contains(value) {
                    return input.index(after: index)
                }
                index = input.index(after: index)
            }
            return nil
        case "]", "P", "X", "^", "_":
            // A string (OSC, DCS, SOS, PM, APC): up to BEL or ESC \. A
            // newline ends a broken one too, and one past maxEscapeLength
            // is dropped: without an end, it swallowed everything after it.
            index = input.index(after: index)
            while index < input.endIndex {
                if input[index] == "\u{07}" { return input.index(after: index) }
                if input[index] == "\n" || input[index] == "\r\n" { return index }
                if input[index] == "\u{1B}" {
                    let next = input.index(after: index)
                    guard next < input.endIndex else { return nil }
                    if input[next] == "\\" { return input.index(after: next) }
                }
                index = input.index(after: index)
            }
            return input.distance(from: start, to: input.endIndex) > maxEscapeLength ? input.endIndex : nil
        case "(", ")", "#":
            let next = input.index(after: index)
            return next < input.endIndex ? input.index(after: next) : nil
        default:
            return input.index(after: index)
        }
    }
}

/// What the terminal panel says of new output after a command: the
/// command's own line (the prompt and the echoed command, which VoiceOver
/// already said as it was typed) and the next prompt are left out, so it's
/// just the result.
public enum TerminalAnnouncement {
    /// `previousLine` is the last line already announced, which is the
    /// prompt the command was typed at when the prompt itself was announced
    /// before the command.
    public static func newOutput(_ text: String, after command: String?, previousLine: String? = nil) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let command, !command.isEmpty, let first = lines.first, first.hasSuffix(command) else {
            return text
        }
        var prompt = String(first.dropLast(command.count)).trimmingCharacters(in: .whitespaces)
        if prompt.isEmpty, let previousLine { prompt = previousLine.trimmingCharacters(in: .whitespaces) }
        lines.removeFirst()
        if !prompt.isEmpty, lines.last?.trimmingCharacters(in: .whitespaces) == prompt {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
