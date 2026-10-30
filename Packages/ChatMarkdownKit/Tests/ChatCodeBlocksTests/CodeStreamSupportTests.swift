import Foundation
import Testing
@testable import ChatCodeBlocks

struct CodeStreamReconcilerTests {
    @Test func canonicalBodyStripsSingleTrailingNewline() {
        #expect(CodeStreamReconciler.canonicalBody("abc\n") == "abc")
        #expect(CodeStreamReconciler.canonicalBody("abc") == "abc")
        #expect(CodeStreamReconciler.canonicalBody("abc\n\n") == "abc\n")
        #expect(CodeStreamReconciler.canonicalBody("") == "")
    }

    @Test func pureAppendSnapshotsProduceLineDeltas() throws {
        let document = CodeBlockDocument()
        var applied = ""

        // The synthetic-trailing-newline sequence the parser actually emits
        // while tokens stream mid-line: "let" → "let x\n" is NOT a string
        // prefix of "let\n", but canonically it is.
        let snapshots = ["let\n", "let x = 1\n", "let x = 1\nprint(x)\n", "let x = 1\nprint(x)\ndone()\n"]
        for snapshot in snapshots {
            let delta = CodeStreamReconciler.applySnapshot(
                rawText: snapshot, appliedBody: &applied, document: document
            )
            try #require(delta != nil, "snapshot \(snapshot.debugDescription) should be a pure append")
        }
        #expect(document.lineCount == 3)
        #expect(document.line(at: 0) == "let x = 1")
        #expect(document.line(at: 2) == "done()")
    }

    @Test func divergentSnapshotReturnsNilForRebuild() {
        let document = CodeBlockDocument()
        var applied = ""
        _ = CodeStreamReconciler.applySnapshot(rawText: "original content\n", appliedBody: &applied, document: document)

        let delta = CodeStreamReconciler.applySnapshot(
            rawText: "rewritten entirely\n", appliedBody: &applied, document: document
        )
        #expect(delta == nil)
        // Caller contract: rebuild.
        let body = CodeStreamReconciler.canonicalBody("rewritten entirely\n")
        document.reset(to: body)
        #expect(document.lineCount == 1)
        #expect(document.line(at: 0) == "rewritten entirely")
    }

    @Test func identicalSnapshotIsAnEmptyDelta() throws {
        let document = CodeBlockDocument()
        var applied = ""
        _ = CodeStreamReconciler.applySnapshot(rawText: "same\n", appliedBody: &applied, document: document)
        let delta = CodeStreamReconciler.applySnapshot(rawText: "same\n", appliedBody: &applied, document: document)
        try #require(delta != nil)
        #expect(delta!.appendedLines.isEmpty)
        #expect(delta!.modifiedLine == nil)
    }

    @Test func exactByteSnapshotsExtractSuffixWithoutCharacterTraversal() throws {
        let prefix = String(repeating: "let café = \"👩🏽‍💻 e\u{301}\"\n", count: 5_000)
        let appended = "print(café)\n"
        let suffix = try #require(CodeStreamReconciler.snapshotSuffix(in: prefix + appended, after: prefix))
        #expect(suffix.text == appended)
        #expect(suffix.suffixCharacterTraversalDistance == 0)
        let same = try #require(CodeStreamReconciler.snapshotSuffix(in: prefix, after: prefix))
        #expect(same.text.isEmpty)
        #expect(same.suffixCharacterTraversalDistance == 0)
    }

    @Test func canonicalEquivalentSnapshotsKeepCharacterBasedSuffixSemantics() throws {
        let document = CodeBlockDocument(text: "café")
        var applied = "café"
        let raw = "cafe\u{301}\nnext 👩🏽‍💻\n"
        let body = CodeStreamReconciler.canonicalBody(raw)
        let suffix = try #require(CodeStreamReconciler.snapshotSuffix(in: body, after: applied))
        #expect(suffix.text == "\nnext 👩🏽‍💻")
        #expect(suffix.suffixCharacterTraversalDistance > 0)
        let delta = try #require(CodeStreamReconciler.applySnapshot(rawText: raw, appliedBody: &applied, document: document))
        #expect(delta.modifiedLine == nil)
        #expect(delta.appendedLines == 1..<2)
        #expect(document.text == "café\nnext 👩🏽‍💻")
        #expect(Array(applied.utf8) == Array(body.utf8))
    }

    @Test func snapshotFastPathPreservesDivergenceAndUnicodeBoundaryRules() {
        for (body, prefix) in [("éx", "e"), ("👩🏽‍💻!", "👩"), ("abc\0changed", "abc\0before"), ("a\r\nb", "a\r")] {
            // Preserve String.hasPrefix's grapheme/canonical-equivalence rules,
            // even when the byte sequence alone looks like a prefix.
            #expect((CodeStreamReconciler.snapshotSuffix(in: body, after: prefix) != nil) == body.hasPrefix(prefix))
        }
        #expect(CodeStreamReconciler.snapshotSuffix(in: "a\0b\nmore", after: "a\0b")?.text == "\nmore")
        let document = CodeBlockDocument(text: "previous 👩🏽‍💻")
        var applied = document.text
        let before = applied
        #expect(CodeStreamReconciler.applySnapshot(rawText: "changed\n", appliedBody: &applied, document: document) == nil)
        #expect(applied == before)
        #expect(document.text == before)
    }

    @Test func everyScalarBoundaryMatchesStringPrefixAndSuffixSemantics() {
        let bodies = ["e\u{301} café\nnext", "👩🏽‍💻👨‍👩‍👧‍👦!", "a\r\nb\n", "🇺🇸🇨🇦!", "\u{600}a\u{301}b", "a\0b", "plain text", ""]
        for body in bodies {
            for scalarIndex in Array(body.unicodeScalars.indices) + [body.unicodeScalars.endIndex] {
                let prefix = String(body.unicodeScalars[..<scalarIndex])
                let result = CodeStreamReconciler.snapshotSuffix(in: body, after: prefix)
                #expect((result != nil) == body.hasPrefix(prefix), "prefix \(prefix.debugDescription) in \(body.debugDescription)")
                if body.hasPrefix(prefix) {
                    #expect(result?.text == String(body.dropFirst(prefix.count)))
                    #expect(result?.suffixCharacterTraversalDistance == 0)
                }
            }
        }
    }

    @Test func arbitraryUnicodeSnapshotSuffixesMatchPreviousStringSemantics() {
        var state: UInt64 = 0xA0761D6478BD642F
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 32) % UInt64(bound))
        }
        let fragments = ["a", "é", "e\u{301}", "\r", "\n", "👩", "🏽", "\u{200D}", "💻", "🇺", "🇸", "\u{600}", "\u{301}", "\0", "!"]
        for iteration in 0..<2_500 {
            let body = (0..<next(32)).map { _ in fragments[next(fragments.count)] }.joined()
            let scalarCount = body.unicodeScalars.count
            var prefix = String(body.unicodeScalars.prefix(next(scalarCount + 1)))
            switch iteration % 4 {
            case 0: prefix = prefix.precomposedStringWithCanonicalMapping
            case 1: prefix = prefix.decomposedStringWithCanonicalMapping
            case 2: prefix += fragments[next(fragments.count)]
            default: break
            }
            let expected = body.hasPrefix(prefix) ? String(body.dropFirst(prefix.count)) : nil
            let actual = CodeStreamReconciler.snapshotSuffix(in: body, after: prefix)
            #expect(actual.map { Array($0.text.utf8) } == expected.map { Array($0.utf8) }, "body \(body.debugDescription), prefix \(prefix.debugDescription)")
        }
    }
}

struct CodeAccessibilityChunkerTests {
    private func makeDocument(lines: Int) -> CodeBlockDocument {
        CodeBlockDocument(text: (0..<lines).map { "line \($0)" }.joined(separator: "\n"))
    }

    @Test func chunksAlignToFixedBoundaries() throws {
        let document = makeDocument(lines: 100)
        // A viewport in the middle of the document.
        let chunks = CodeAccessibilityChunker.chunks(covering: 30..<55, document: document, chunkSize: 12)
        try #require(!chunks.isEmpty)
        // 30/12 = 2, (55-1)/12 = 4 → chunks 2, 3, 4 covering rows 24..<60.
        #expect(chunks.map(\.index) == [2, 3, 4])
        #expect(chunks.first?.rows == 24..<36)
        #expect(chunks.last?.rows == 48..<60)
    }

    @Test func chunkIdentityIsStableAsViewportMoves() {
        let document = makeDocument(lines: 100)
        let before = CodeAccessibilityChunker.chunks(covering: 20..<40, document: document, chunkSize: 12)
        let after = CodeAccessibilityChunker.chunks(covering: 25..<45, document: document, chunkSize: 12)
        let sharedIndices = Set(before.map(\.index)).intersection(after.map(\.index))
        #expect(!sharedIndices.isEmpty)
        for index in sharedIndices {
            let a = before.first { $0.index == index }!
            let b = after.first { $0.index == index }!
            #expect(a == b) // same rows, same label — same element, focus survives
        }
    }

    @Test func labelsAnnounceHumanLineNumbers() throws {
        let document = makeDocument(lines: 30)
        let chunks = CodeAccessibilityChunker.chunks(covering: 0..<10, document: document, chunkSize: 12)
        try #require(chunks.count == 1)
        #expect(chunks[0].label.hasPrefix("Lines 1 to 12 of 30:"))
        #expect(chunks[0].label.contains("line 0"))
        #expect(chunks[0].label.contains("line 11"))
    }

    @Test func rangesClampToDocumentBounds() throws {
        let document = makeDocument(lines: 20)
        let chunks = CodeAccessibilityChunker.chunks(covering: 12..<500, document: document, chunkSize: 12)
        try #require(chunks.count == 1)
        #expect(chunks[0].rows == 12..<20)
        #expect(chunks[0].label.hasPrefix("Lines 13 to 20 of 20:"))

        let empty = CodeAccessibilityChunker.chunks(covering: 0..<10, document: CodeBlockDocument(), chunkSize: 12)
        #expect(empty.isEmpty)
    }

    @Test func tenThousandLinesMaterializeOnlyViewportChunks() {
        let document = makeDocument(lines: 10_000)
        let chunks = CodeAccessibilityChunker.chunks(covering: 5_000..<5_040, document: document, chunkSize: 12)
        #expect(chunks.count <= 5)
        #expect(chunks.allSatisfy { $0.rows.count <= 12 })
    }
}

/// Single-chunk materialization — keeps the VoiceOver-focused chunk alive
/// outside the visible window.
struct CodeChunkAtIndexTests {
    private func makeDocument(lines: Int) -> CodeBlockDocument {
        CodeBlockDocument(text: (0..<lines).map { "line \($0)" }.joined(separator: "\n"))
    }

    @Test func chunkAtIndexMatchesCoveringChunks() {
        let document = makeDocument(lines: 100)
        let covering = CodeAccessibilityChunker.chunks(covering: 0..<100, document: document)
        for chunk in covering {
            let single = CodeAccessibilityChunker.chunk(at: chunk.index, document: document)
            #expect(single == chunk)
        }
    }

    @Test func chunkBeyondDocumentIsNil() {
        let document = makeDocument(lines: 10)
        #expect(CodeAccessibilityChunker.chunk(at: 1, document: document) == nil)
        #expect(CodeAccessibilityChunker.chunk(at: -1, document: document) == nil)
        #expect(CodeAccessibilityChunker.chunk(at: 0, document: CodeBlockDocument()) == nil)
    }

    @Test func partialTailChunkClampsToLineCount() throws {
        let document = makeDocument(lines: 30) // chunks of 12: 0..<12, 12..<24, 24..<30
        let tail = try #require(CodeAccessibilityChunker.chunk(at: 2, document: document))
        #expect(tail.rows == 24..<30)
        #expect(tail.label.hasPrefix("Lines 25 to 30 of 30:"))
    }

    @Test func chunkIndexForRowIsStable() {
        #expect(CodeAccessibilityChunker.chunkIndex(forRow: 0) == 0)
        #expect(CodeAccessibilityChunker.chunkIndex(forRow: 11) == 0)
        #expect(CodeAccessibilityChunker.chunkIndex(forRow: 12) == 1)
        #expect(CodeAccessibilityChunker.chunkIndex(forRow: 500) == 41)
        #expect(CodeAccessibilityChunker.chunkIndex(forRow: -5) == 0)
    }
}
