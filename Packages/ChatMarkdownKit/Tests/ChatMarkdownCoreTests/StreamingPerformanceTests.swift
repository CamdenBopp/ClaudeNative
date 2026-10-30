import Testing
@testable import ChatMarkdownCore

/// Coarse regression tripwires, not benchmarks: bounds are ~10× looser than
/// measured so they only fail on complexity regressions (e.g. something
/// reintroducing full-source reparses per token), never on machine noise.
struct StreamingPerformanceTests {
    @Test(.timeLimit(.minutes(1)))
    func fiveThousandLineCodeStreamAvoidsMarkdownReparses() {
        let clock = ContinuousClock()
        let assembler = StreamingMessageAssembler(messageID: MessageID("perf-code"))
        assembler.append("Intro paragraph.\n\n```swift\n")

        let elapsed = clock.measure {
            for index in 0..<5_000 {
                assembler.append("let value\(index) = compute(\(index)) + offset\n")
            }
        }
        // Every append must take the fast path — zero Markdown parses.
        #expect(assembler.fastCodePathCount == 5_000)
        #expect(elapsed < .seconds(2))

        assembler.append("```\n")
        let final = assembler.finish()
        guard case .codeBlock(let code) = final.document.blocks[1].content else {
            Issue.record("expected code block")
            return
        }
        #expect(code.isClosed)
        #expect(code.rawText.contains("let value4999"))
    }

    @Test(.timeLimit(.minutes(1)))
    func longProseStreamKeepsReparseWindowBounded() {
        let clock = ContinuousClock()
        let assembler = StreamingMessageAssembler(messageID: MessageID("perf-prose"))

        let elapsed = clock.measure {
            for index in 0..<500 {
                assembler.append("Sentence one of paragraph \(index). ")
                assembler.append("Sentence two, a bit longer, with more words in it.")
                assembler.append("\n\n")
            }
        }
        #expect(elapsed < .seconds(3))
        #expect(assembler.currentDocument.blocks.count == 500)
        // The frozen prefix must cover almost everything.
        let tailBytes = assembler.sourceText.utf8.count - assembler.frozenUTF8Length
        #expect(tailBytes < 300)
    }

    /// Reconcile work must be linear in appends, not quadratic in block count.
    /// The frozen prefix is immutable, so each append should only re-diff the
    /// unfrozen tail (a couple of blocks) — not the whole accumulated document.
    /// A full per-append diff makes total comparisons ~N²/2; tail-only keeps
    /// them ~c·N. Deterministic (counts work, not time), so it is a genuine
    /// complexity tripwire rather than a machine-noise bound.
    @Test func proseReconcileStaysLinearInBlockCount() {
        let assembler = StreamingMessageAssembler(messageID: MessageID("perf-reconcile"))
        let paragraphs = 800
        for index in 0..<paragraphs {
            assembler.append("Paragraph \(index) with a few words of content.\n\n")
        }
        #expect(assembler.currentDocument.blocks.count == paragraphs)
        // Tail-only reconcile examines O(1) blocks per append. Allow generous
        // slack (a handful of tail blocks per append) but far below the ~320k
        // (N²/2) a whole-document diff would rack up at N = 800.
        #expect(
            assembler.reconciledBlockComparisons < paragraphs * 8,
            "reconcile did \(assembler.reconciledBlockComparisons) comparisons for \(paragraphs) paragraphs — expected linear (< \(paragraphs * 8)), got quadratic-looking growth"
        )
    }
}
