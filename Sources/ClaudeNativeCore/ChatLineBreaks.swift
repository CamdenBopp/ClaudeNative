import Foundation

/// Chat replies treat a single newline as a line break, as claude.ai shows
/// them. CommonMark folds it into a space, so "1 1\n2 4" would read
/// "1 1 2 4". This marks each newline outside code fences as a hard break
/// (two trailing spaces) before the text is parsed.
public enum ChatLineBreaks {
    /// The text with hard breaks added. As `text` grows, the result only
    /// grows at its end, so a streaming parser can keep appending to it.
    public static func hardened(_ text: String) -> String {
        var stream = Stream()
        return stream.append(text)
    }

    /// Hardens a reply as it streams, looking only at each new piece (and the
    /// line it finishes), so a long reply costs time in proportion to its
    /// length rather than its length times its deltas. Joining every result
    /// of `append` gives exactly `hardened` of the whole text.
    public struct Stream: Sendable {
        /// The fence the text is inside, if any.
        private var fence: String?
        /// The current line so far: everything after the last newline.
        private var line = ""
        /// Whether the text so far ends in a carriage return. "\r\n" is one
        /// Character, so a newline right after one does not end a line, even
        /// when the two arrive in different pieces.
        private var endsInCarriageReturn = false
        /// UTF-8 bytes looked at so far, including each finished line once
        /// more; a test counts it to keep the work linear.
        public private(set) var scannedUTF8 = 0

        public init() {}

        /// The hardened text for `piece`, which continues the text appended
        /// so far.
        public mutating func append(_ piece: String) -> String {
            var out = ""
            out.reserveCapacity(piece.utf8.count + piece.utf8.count / 16)
            scannedUTF8 += piece.utf8.count
            let scalars = piece.unicodeScalars
            var start = scalars.startIndex
            var index = start
            var afterCarriageReturn = endsInCarriageReturn
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if scalar == "\n", !afterCarriageReturn {
                    let part = String(scalars[start..<index])
                    line += part
                    out += part
                    out += endOfLine()
                    out += "\n"
                    line = ""
                    start = scalars.index(after: index)
                }
                afterCarriageReturn = scalar == "\r"
                index = scalars.index(after: index)
            }
            let rest = String(scalars[start...])
            line += rest
            out += rest
            endsInCarriageReturn = afterCarriageReturn
            return out
        }

        /// What goes before the newline ending `line`: two spaces for a hard
        /// break, or nothing inside a fence, on a fence, on a blank line, or
        /// after a line that already breaks.
        private mutating func endOfLine() -> String {
            scannedUTF8 += line.utf8.count
            let marker = ChatLineBreaks.fenceMarker(Substring(line))
            if let open = fence {
                if let marker, marker.first == open.first, marker.count >= open.count {
                    fence = nil
                }
                return ""
            }
            if let marker {
                fence = String(marker)
                return ""
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasSuffix("  ") || line.hasSuffix("\\") {
                return ""
            }
            return "  "
        }
    }

    /// The run of backticks or tildes opening or closing a fence, if `line`
    /// is one (up to three spaces of indent, at least three marks).
    static func fenceMarker(_ line: Substring) -> Substring? {
        let indent = line.prefix { $0 == " " }
        guard indent.count <= 3 else { return nil }
        let rest = line.dropFirst(indent.count)
        guard let mark = rest.first, mark == "`" || mark == "~" else { return nil }
        let run = rest.prefix { $0 == mark }
        return run.count >= 3 ? run : nil
    }
}
