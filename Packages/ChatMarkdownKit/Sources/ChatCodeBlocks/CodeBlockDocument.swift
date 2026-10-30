import Foundation

/// What one append changed, in line indices. The code renderer re-lays-out
/// only these lines; everything else keeps its cached CTLine.
public struct CodeLineDelta: Hashable, Sendable {
    /// Line whose content grew because the chunk extended it (the previous
    /// last line), or nil if the chunk started cleanly on a new line.
    public let modifiedLine: Int?
    /// Indices of newly created lines (empty range if none).
    public let appendedLines: Range<Int>

    public init(modifiedLine: Int?, appendedLines: Range<Int>) {
        self.modifiedLine = modifiedLine
        self.appendedLines = appendedLines
    }

    /// Whether this delta touches any of the given rows — the redraw gate:
    /// appends beyond the visible viewport need no repaint.
    public func touches(_ rows: Range<Int>) -> Bool {
        if let modifiedLine, rows.contains(modifiedLine) {
            return true
        }
        return appendedLines.overlaps(rows)
    }
}

/// Append-only, line-oriented storage for one code block.
///
/// Line orientation is the load-bearing decision (Runestone's model): layout,
/// highlighting, caching, and accessibility all address lines, so a 10,000-line
/// block only ever does work proportional to the visible range plus the lines
/// an append touched.
///
/// v0 stores one String per line. Because chat code blocks are append-only
/// (LLM output is never edited in place), a plain array is exact — no
/// red-black tree needed until arbitrary edits exist. If per-line String
/// overhead shows up in profiling, the upgrade is chunked contiguous storage
/// behind this same API.
///
/// Not Sendable by design: owned by a single code-block engine (actor in the
/// full architecture); it emits value deltas.
public final class CodeBlockDocument {
    public private(set) var lines: [String] = []

    public init() {}

    public init(text: String) {
        if !text.isEmpty {
            append(text)
        }
    }

    public var lineCount: Int { lines.count }

    public func line(at index: Int) -> String {
        lines[index]
    }

    /// Full text reconstruction — for "copy entire block".
    public var text: String {
        lines.joined(separator: "\n")
    }

    /// Wholesale replacement — the divergence fallback when a reparse changed
    /// existing content (rare; streaming appends never need this).
    public func reset(to text: String) {
        lines = []
        if !text.isEmpty {
            append(text)
        }
    }

    @discardableResult
    public func append(_ chunk: String) -> CodeLineDelta {
        guard !chunk.isEmpty else {
            return CodeLineDelta(modifiedLine: nil, appendedLines: lines.count..<lines.count)
        }
        let pieces = chunk.components(separatedBy: "\n")

        if lines.isEmpty {
            lines = pieces
            return CodeLineDelta(modifiedLine: nil, appendedLines: 0..<lines.count)
        }

        var modified: Int? = nil
        if !pieces[0].isEmpty {
            lines[lines.count - 1] += pieces[0]
            modified = lines.count - 1
        }
        let firstAppended = lines.count
        lines.append(contentsOf: pieces.dropFirst())
        return CodeLineDelta(modifiedLine: modified, appendedLines: firstAppended..<lines.count)
    }
}
