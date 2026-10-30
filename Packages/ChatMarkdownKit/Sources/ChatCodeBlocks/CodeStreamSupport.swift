import Foundation

/// Reconciles parser rawText snapshots against a line document.
///
/// The parser reports the *entire* code body on every update, and cmark
/// normalizes it with a trailing newline even when the source is mid-line.
/// Comparing canonical bodies (trailing newline stripped) makes consecutive
/// snapshots pure prefix-extensions of each other during streaming, so the
/// document only ever appends. Validating a complete snapshot still compares
/// its existing prefix; suffix extraction and line storage touch only new text.
public enum CodeStreamReconciler {
    /// The parser's rawText with its single trailing newline stripped — the
    /// form under which streaming snapshots grow monotonically.
    public static func canonicalBody(_ rawText: String) -> String {
        rawText.hasSuffix("\n") ? String(rawText.dropLast()) : rawText
    }

    /// Applies a new rawText snapshot. Returns the line delta when the
    /// snapshot extends the applied body (the streaming case, including an
    /// empty extension); returns nil when content diverged — the caller
    /// rebuilds via `CodeBlockDocument.reset(to:)`.
    public static func applySnapshot(
        rawText: String,
        appliedBody: inout String,
        document: CodeBlockDocument
    ) -> CodeLineDelta? {
        let body = canonicalBody(rawText)
        guard let suffix = snapshotSuffix(in: body, after: appliedBody) else { return nil }
        appliedBody = body
        return document.append(suffix.text)
    }

    /// Most parser snapshots preserve the exact UTF-8 bytes of the previously
    /// applied body. Seek past that prefix by bytes instead of counting and
    /// advancing over every grapheme twice. Keep String's canonical-equivalent
    /// prefix behavior for externally supplied snapshots with different Unicode
    /// encodings; byte offsets cannot be reused for that case.
    static func snapshotSuffix(in body: String, after prefix: String) -> (text: String, suffixCharacterTraversalDistance: Int)? {
        guard body.hasPrefix(prefix) else { return nil }
        let prefixByteCount = prefix.utf8.count
        let hasExactBytes = body.utf8.count >= prefixByteCount && body.withCString { bodyBytes in
            prefix.withCString { prefixBytes in
                memcmp(bodyBytes, prefixBytes, prefixByteCount) == 0
            }
        }
        if hasExactBytes {
            let start = body.utf8.index(body.utf8.startIndex, offsetBy: prefixByteCount)
            return (String(body[start...]), 0)
        }
        let characterCount = prefix.count
        let start = body.index(body.startIndex, offsetBy: characterCount)
        return (String(body[start...]), characterCount * 2)
    }
}

/// One VoiceOver navigation unit over a code block: a fixed-size group of
/// lines. Chunks are aligned to `chunkSize` boundaries so a chunk's identity
/// (its index) is stable as the viewport moves and as lines append — which
/// keeps VoiceOver focus on "the same chunk" across updates.
public struct CodeAccessibilityChunk: Equatable, Sendable {
    public let index: Int
    public let rows: Range<Int>
    public let label: String
}

/// Chunked accessibility navigation for large code blocks: a screen-reader
/// user swipes through ~dozen-line chunks instead of thousands of tokens,
/// and only chunks near the viewport materialize.
public enum CodeAccessibilityChunker {
    public static let defaultChunkSize = 12

    public static func chunks(
        covering visibleRows: Range<Int>,
        document: CodeBlockDocument,
        chunkSize: Int = defaultChunkSize
    ) -> [CodeAccessibilityChunk] {
        guard chunkSize > 0, document.lineCount > 0, !visibleRows.isEmpty else { return [] }
        let clampedLower = max(0, min(visibleRows.lowerBound, document.lineCount - 1))
        let clampedUpper = max(clampedLower + 1, min(visibleRows.upperBound, document.lineCount))
        let firstChunk = clampedLower / chunkSize
        let lastChunk = (clampedUpper - 1) / chunkSize

        return (firstChunk...lastChunk).compactMap { chunkIndex in
            chunk(at: chunkIndex, document: document, chunkSize: chunkSize)
        }
    }

    /// Materializes one chunk by index — used to keep the VoiceOver-focused
    /// chunk alive in the accessibility tree even after it scrolls outside
    /// the materialized window (pruning the focused element strands the
    /// user's focus and forces touch exploration to recover).
    public static func chunk(
        at chunkIndex: Int,
        document: CodeBlockDocument,
        chunkSize: Int = defaultChunkSize
    ) -> CodeAccessibilityChunk? {
        guard chunkSize > 0, chunkIndex >= 0 else { return nil }
        let start = chunkIndex * chunkSize
        let end = min(document.lineCount, start + chunkSize)
        guard start < end else { return nil }
        let rows = start..<end
        let text = rows.map { document.line(at: $0) }.joined(separator: "\n")
        let label = "Lines \(rows.lowerBound + 1) to \(rows.upperBound) of \(document.lineCount): \(text)"
        return CodeAccessibilityChunk(index: chunkIndex, rows: rows, label: label)
    }

    /// The chunk index containing a row.
    public static func chunkIndex(forRow row: Int, chunkSize: Int = defaultChunkSize) -> Int {
        max(0, row) / max(1, chunkSize)
    }
}
