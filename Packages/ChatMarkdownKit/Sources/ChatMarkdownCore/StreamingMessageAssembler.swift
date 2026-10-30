import Foundation

/// Accumulates a token stream for one message and maintains a parsed document
/// with stable block identity.
///
/// Not Sendable by design: exactly one owner (the per-message renderer actor)
/// mutates it; everything it emits is a Sendable value snapshot.
///
/// ## Incremental strategy
///
/// Appends never reparse the whole message. Three tiers, cheapest first:
///
/// 1. **Open-fence fast path.** While the tail block is an unclosed fenced
///    code block and the chunk cannot contain a fence marker (no backticks or
///    tildes), the chunk appends straight into the code block's text — no
///    Markdown parse at all. Syntax work is proportional to the arriving
///    chunk; emitting immutable whole-body String snapshots can still copy
///    the accumulated body as it grows.
/// 2. **Tail-only reparse.** Otherwise only `tailText` — the source after the
///    frozen prefix — is reparsed. The frozen prefix advances whenever the
///    tail contains at least two blocks: everything before the last block
///    freezes, provided the last block starts at column 0 immediately after a
///    blank line (so no CommonMark construct can merge backward across the
///    boundary).
/// 3. **Full reparse fallback.** Link-reference definitions can retroactively
///    change *earlier* blocks (`[text][ref]` resolves once `[ref]: url`
///    arrives), so the moment any appended line looks like a definition,
///    freezing is disabled for the message and parses cover the full source.
///    `finish()` always runs one final full parse as a self-check.
///
/// Correctness of the spliced (frozen + tail) parse against a full parse is
/// enforced by differential fuzz tests, not by trusting this comment.
///
/// ## Identity
///
/// After parsing, a positional diff against the previous block list assigns
/// identity: same position + same kind keeps the `BlockID` (bumping the
/// revision if content changed); a kind change in place is a remove+insert.
/// Positional diffing is exact for append-only streams because completed
/// blocks never reorder.
public final class StreamingMessageAssembler {
    public let messageID: MessageID

    public private(set) var sourceText: String = ""
    public private(set) var currentDocument: MarkdownDocument

    private var nextBirthOrder = 0

    // Tail-only reparse state.
    private var frozenContents: [BlockContent] = []
    private var tailText: String = ""
    private var freezeDisabled = false
    /// UTF-8 length of the frozen source prefix (== sourceText length minus
    /// tailText length). Internal for tests.
    private(set) var frozenUTF8Length = 0

    /// Accumulated body of the currently open fenced code block, kept only
    /// while the fast path is armed (see `append`). `nil` means the next
    /// code-block chunk takes the parse path once, re-arming afterwards.
    private var openCodeAccumulator: String?

    // Instrumentation (internal, read by tests and dev telemetry).
    private(set) var tailParseCount = 0
    private(set) var fullParseCount = 0
    private(set) var fastCodePathCount = 0
    /// Total block comparisons performed across every reconcile — a complexity
    /// tripwire. Reconciling only the tail (the frozen prefix is immutable)
    /// keeps this linear in appends; diffing the whole block list each append
    /// makes it quadratic in block count.
    private(set) var reconciledBlockComparisons = 0

    public init(messageID: MessageID) {
        self.messageID = messageID
        self.currentDocument = .empty(messageID: messageID)
    }

    // MARK: - Public API

    /// Appends a raw token chunk (any string, including partial syntax) and
    /// returns the resulting delta.
    @discardableResult
    public func append(_ chunk: String) -> DocumentDelta {
        guard !chunk.isEmpty else {
            return DocumentDelta(document: currentDocument, insertedBlockIDs: [], updatedBlockIDs: [], removedBlockIDs: [])
        }
        let boundaryByte = sourceText.utf8.last
        sourceText += chunk
        tailText += chunk

        if !freezeDisabled, chunkMayIntroduceLinkReferenceDefinition(chunk, boundaryByte: boundaryByte) {
            // Definitions rewrite history; give up on incrementality for this
            // message rather than risk stale earlier blocks.
            freezeDisabled = true
            frozenContents = []
            frozenUTF8Length = 0
            tailText = sourceText
            openCodeAccumulator = nil
        }

        if let delta = fastCodeAppend(chunk) {
            return delta
        }
        return reparse(isComplete: false)
    }

    /// Marks the stream finished. Runs one full-source parse (cheap once, and
    /// it self-corrects any splice drift) and emits a final delta.
    @discardableResult
    public func finish() -> DocumentDelta {
        reparse(isComplete: true)
    }

    // MARK: - Tier 1: open-fence fast path

    private func fastCodeAppend(_ chunk: String) -> DocumentDelta? {
        guard var accumulator = openCodeAccumulator,
              // Backtick/tilde could be a fence marker; carriage returns get
              // normalized by cmark, so byte-appending them would diverge
              // from a real parse. All three fall through to the parse path.
              // Scalar-level contains, NOT Character-level: "\r\n" is one
              // grapheme, so Character-contains never sees the "\r" in it.
              !chunk.unicodeScalars.contains("`"),
              !chunk.unicodeScalars.contains("~"),
              !chunk.unicodeScalars.contains("\r"),
              let lastBlock = currentDocument.blocks.last,
              case .codeBlock(var code) = lastBlock.content,
              !code.isClosed
        else {
            return nil
        }
        fastCodePathCount += 1
        RenderSignposts.streaming.emitEvent("stream.fastPath")
        accumulator += chunk
        openCodeAccumulator = accumulator
        code.rawText = Self.normalizedCodeBody(accumulator)

        var blocks = currentDocument.blocks
        let updatedBlock = MarkdownBlock(
            id: lastBlock.id,
            revision: lastBlock.revision.next(),
            content: .codeBlock(code)
        )
        blocks[blocks.count - 1] = updatedBlock
        currentDocument = MarkdownDocument(
            messageID: messageID,
            revision: currentDocument.revision.next(),
            blocks: blocks,
            isComplete: false
        )
        return DocumentDelta(
            document: currentDocument,
            insertedBlockIDs: [],
            updatedBlockIDs: [lastBlock.id],
            removedBlockIDs: []
        )
    }

    /// cmark terminates fenced code content with a newline even when the
    /// source does not (yet); the accumulator stores the raw source so joins
    /// stay exact, and presentation normalizes. Scalar-level suffix check so
    /// a CRLF-final body isn't mistaken for newline-less.
    static func normalizedCodeBody(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        return raw.unicodeScalars.last == "\n" ? raw : raw + "\n"
    }

    // MARK: - Tiers 2/3: reparse + reconcile

    private func reparse(isComplete: Bool) -> DocumentDelta {
        if isComplete || freezeDisabled {
            return RenderSignposts.streaming.withIntervalSignpost("stream.fullReparse") {
                performReparse(isComplete: isComplete)
            }
        }
        return RenderSignposts.streaming.withIntervalSignpost("stream.tailReparse") {
            performReparse(isComplete: isComplete)
        }
    }

    private func performReparse(isComplete: Bool) -> DocumentDelta {
        var parsedTail: [MarkdownConverter.ParsedBlock]

        if isComplete {
            fullParseCount += 1
            parsedTail = CmarkDirectParser.parsedBlocks(from: sourceText)
            frozenContents = []
            frozenUTF8Length = 0
            tailText = sourceText
        } else {
            let tailSource = freezeDisabled ? sourceText : tailText
            tailParseCount += 1
            parsedTail = CmarkDirectParser.parsedBlocks(from: tailSource)
            // The open-fence downgrade only ever applies to the tail's last
            // block (a top-level streaming code block), so patch `parsedTail`
            // directly — no need to materialize the frozen prefix to reach it.
            if case .some(.codeBlock(var tailCode)) = parsedTail.last?.content,
               Self.hasUnclosedFence(tailSource) {
                tailCode.isClosed = false
                parsedTail[parsedTail.count - 1] = .init(
                    content: .codeBlock(tailCode),
                    range: parsedTail[parsedTail.count - 1].range
                )
            }
        }

        // The frozen prefix is immutable; only the tail is reconciled. Building
        // `frozenContents + parsedTail` (and diffing all of it) every append is
        // what made comparison work O(blocks²) — see `reconcile`. Emitting a
        // value snapshot still copies the growing blocks array.
        let tailContents = parsedTail.map(\.content)
        let frozenPrefixCount = isComplete || freezeDisabled ? 0 : frozenContents.count
        armCodeFastPath(isComplete: isComplete, lastContent: tailContents.last)
        let delta = reconcile(
            frozenPrefixCount: frozenPrefixCount, tailContents: tailContents, isComplete: isComplete
        )
        if !isComplete, !freezeDisabled {
            advanceFreeze(parsedTail: parsedTail)
        }
        return delta
    }

    private func armCodeFastPath(isComplete: Bool, lastContent: BlockContent?) {
        openCodeAccumulator = nil
        guard !isComplete,
              case .some(.codeBlock(let code)) = lastContent,
              !code.isClosed,
              // Arm only when the source ends at a line boundary: then the
              // parser's reported body equals the raw source body exactly
              // (modulo cmark's CRLF→LF normalization, which the accumulator
              // inherits by copying the parser's rawText) and future raw
              // appends stay byte-accurate — \r-bearing chunks are already
              // routed to the parse path. Scalar-level so "\r\n" endings arm.
              sourceText.unicodeScalars.last == "\n"
        else { return }
        openCodeAccumulator = code.rawText
    }

    private func reconcile(
        frozenPrefixCount: Int, tailContents: [BlockContent], isComplete: Bool
    ) -> DocumentDelta {
        let old = currentDocument.blocks
        // The frozen-prefix blocks were built from `frozenContents` and are
        // never revised (freezing only advances, and a reparse touches only the
        // tail), so `old[0..<prefixCount].content == frozenContents` holds by
        // construction. Carrying them verbatim is byte-identical to diffing
        // them (they always compare equal) and keeps comparisons O(tail): a
        // definition splice that could rewrite history sets `freezeDisabled`,
        // which zeroes the prefix and falls back to a full diff. The spliced
        // result is checked against a full parse by the differential fuzz tests.
        let prefixCount = min(max(frozenPrefixCount, 0), old.count)
        var newBlocks: [MarkdownBlock] = []
        newBlocks.reserveCapacity(prefixCount + tailContents.count)
        newBlocks.append(contentsOf: old[0..<prefixCount])
        var inserted: [BlockID] = []
        var updated: [BlockID] = []
        var removed: [BlockID] = []

        for (offset, content) in tailContents.enumerated() {
            reconciledBlockComparisons += 1
            let index = prefixCount + offset
            if index < old.count {
                let prior = old[index]
                if prior.content == content {
                    newBlocks.append(prior)
                } else if prior.content.kind == content.kind {
                    newBlocks.append(MarkdownBlock(
                        id: prior.id,
                        revision: prior.revision.next(),
                        content: content
                    ))
                    updated.append(prior.id)
                } else {
                    // Kind changed in place (e.g. a tail paragraph "```swift"
                    // resolved into a code block): replace identity.
                    let block = makeBlock(content)
                    newBlocks.append(block)
                    inserted.append(block.id)
                    removed.append(prior.id)
                }
            } else {
                let block = makeBlock(content)
                newBlocks.append(block)
                inserted.append(block.id)
            }
        }
        if prefixCount + tailContents.count < old.count {
            removed.append(contentsOf: old[(prefixCount + tailContents.count)...].map(\.id))
        }

        let changed = !(inserted.isEmpty && updated.isEmpty && removed.isEmpty)
            || currentDocument.isComplete != isComplete
        let revision = changed ? currentDocument.revision.next() : currentDocument.revision

        currentDocument = MarkdownDocument(
            messageID: messageID,
            revision: revision,
            blocks: newBlocks,
            isComplete: isComplete
        )
        return DocumentDelta(
            document: currentDocument,
            insertedBlockIDs: inserted,
            updatedBlockIDs: updated,
            removedBlockIDs: removed
        )
    }

    private func makeBlock(_ content: BlockContent) -> MarkdownBlock {
        defer { nextBirthOrder += 1 }
        return MarkdownBlock(
            id: BlockID(messageID: messageID, birthOrder: nextBirthOrder),
            revision: .zero,
            content: content
        )
    }

    // MARK: - Freeze advancement

    /// Freezes every tail block except the last, when the boundary is safe:
    /// the last block starts at column 0 (no lazy/indented continuation can
    /// reach back) directly after a blank line (no multi-line construct can
    /// merge back).
    private func advanceFreeze(parsedTail: [MarkdownConverter.ParsedBlock]) {
        guard parsedTail.count >= 2,
              let range = parsedTail[parsedTail.count - 1].range,
              range.lowerBound.column == 1
        else { return }

        let bytes = Array(tailText.utf8)
        var lineStarts: [Int] = [0]
        lineStarts.reserveCapacity(128)
        // Plain while over Int, not `for index in bytes.indices where …`:
        // the Range-based form dispatches through Collection witnesses per
        // byte in -Onone builds — a device trace measured it at ~46 ms for
        // one large tail. This loop is the assembler's only per-byte scan.
        var byteIndex = 0
        let byteCount = bytes.count
        while byteIndex < byteCount {
            if bytes[byteIndex] == 0x0A {
                lineStarts.append(byteIndex + 1)
            }
            byteIndex += 1
        }
        let line = range.lowerBound.line
        guard line >= 2, line - 1 < lineStarts.count else { return }
        let boundary = lineStarts[line - 1]
        guard boundary > 0, boundary < bytes.count,
              bytes[boundary] != 0x20, bytes[boundary] != 0x09,
              isPrecededByBlankLine(bytes, at: boundary)
        else { return }

        frozenContents.append(contentsOf: parsedTail.dropLast().map(\.content))
        frozenUTF8Length += boundary
        let cut = tailText.utf8.index(tailText.utf8.startIndex, offsetBy: boundary)
        tailText = String(tailText[cut...])
    }

    private func isPrecededByBlankLine(_ bytes: [UInt8], at boundary: Int) -> Bool {
        guard boundary >= 1, bytes[boundary - 1] == 0x0A else { return false }
        var index = boundary - 2
        // Spaces, tabs, and carriage returns (CRLF endings) are all blank.
        while index >= 0, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0D {
            index -= 1
        }
        return index < 0 || bytes[index] == 0x0A
    }

    // MARK: - Scanners

    /// Stateful open-fence scan modeling CommonMark's matching rules: a fence
    /// closes only on the same character, at least the opening length, with
    /// nothing but spaces after — `​```swift` never closes a backtick fence,
    /// and `~~~` inside an open backtick fence is content.
    ///
    /// Two deliberate approximations, both biased toward "closed" because a
    /// false *open* would let the fast path corrupt content, while a false
    /// *closed* only skips an optimization and briefly mislabels streaming
    /// state (the parser still decides real block structure):
    /// - Openers are recognized at column 0 only (spec allows ≤3 spaces;
    ///   indented openers are rare in LLM output and ambiguous with
    ///   list/quote nesting, which this scanner cannot see).
    /// - Fences inside blockquotes/lists are ignored entirely; the isClosed
    ///   patch only ever applies to a *top-level* tail code block anyway.
    static func hasUnclosedFence(_ text: String) -> Bool {
        var openChar: Unicode.Scalar?
        var openLength = 0
        // Scalar-level line splitting, NOT Character-level: "\r\n" is a
        // single grapheme cluster, so a Character split on "\n" never fires
        // for CRLF sources and the scanner would see the whole document as
        // one line (found by the scalar-boundary fuzzer).
        let newline: Unicode.Scalar = "\n"
        for rawLine in text.unicodeScalars.split(separator: newline, omittingEmptySubsequences: false) {
            var line = rawLine
            if line.last == "\r" { line = line.dropLast() }
            if let open = openChar {
                // Closers may be indented up to 3 spaces.
                var rest = line
                var indent = 0
                while rest.first == " ", indent < 3 {
                    rest = rest.dropFirst()
                    indent += 1
                }
                let runLength = rest.prefix(while: { $0 == open }).count
                if runLength >= openLength, runLength >= 3,
                   rest.dropFirst(runLength).allSatisfy({ $0 == " " }) {
                    openChar = nil
                    openLength = 0
                }
            } else {
                guard let first = line.first, first == "`" || first == "~" else { continue }
                let runLength = line.prefix(while: { $0 == first }).count
                guard runLength >= 3 else { continue }
                let info = line.dropFirst(runLength)
                // Backtick openers may not carry backticks in the info string.
                if first == "`", info.contains("`") { continue }
                openChar = first
                openLength = runLength
            }
        }
        return openChar != nil
    }

    /// Conservative: any "]:" anywhere counts. False positives only cost
    /// performance (full reparses), never correctness. Checks the arriving
    /// chunk plus the previous byte (a definition split exactly at a chunk
    /// boundary), NOT the accumulated tail: `freezeDisabled` is sticky, so
    /// every "]:" only needs to be noticed once — when its bytes arrive.
    /// Scanning the tail's last lines per append was O(line length) per
    /// token, quadratic while a long one-line paragraph streams; this is
    /// O(chunk). Strictly more sensitive than the previous last-two-lines
    /// scan (it also fires for older lines), which is the safe direction.
    private func chunkMayIntroduceLinkReferenceDefinition(_ chunk: String, boundaryByte: UInt8?) -> Bool {
        if boundaryByte == UInt8(ascii: "]"), chunk.utf8.first == UInt8(ascii: ":") {
            return true
        }
        var previous: UInt8 = 0
        for byte in chunk.utf8 {
            if previous == UInt8(ascii: "]"), byte == UInt8(ascii: ":") {
                return true
            }
            previous = byte
        }
        return false
    }

    // MARK: - Test support

    /// The semantics every incremental tier must match: a full parse of the
    /// source with the open-fence patch applied. Differential fuzz tests
    /// compare `currentDocument` against this after every append.
    static func referenceContents(source: String, isComplete: Bool) -> [BlockContent] {
        var contents = MarkdownConverter.blocks(from: source)
        if !isComplete,
           case .some(.codeBlock(var tail)) = contents.last,
           hasUnclosedFence(source) {
            tail.isClosed = false
            contents[contents.count - 1] = .codeBlock(tail)
        }
        return contents
    }
}
