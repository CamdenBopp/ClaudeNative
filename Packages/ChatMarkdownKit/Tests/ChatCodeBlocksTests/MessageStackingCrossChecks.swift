import CoreGraphics
import Testing
import ChatMarkdownCore
@testable import ChatCodeBlocks

/// `MessageStacking` (Core) sizes code blocks without building documents or
/// engines; these tests pin it to the real implementations so measured
/// heights can never drift from rendered heights.
struct MessageStackingCrossChecks {
    @Test func metricsLineHeightMatchesEngineLineHeight() {
        let metrics = MessageLayoutMetrics()
        let engine = CodeBlockLayoutEngine(
            document: CodeBlockDocument(text: "let x = 1"),
            fontName: metrics.codeFontName,
            fontSize: metrics.codeFontSize
        )
        #expect(engine.lineHeight == metrics.codeLineHeight)
    }

    @Test func codeLineCountMatchesDocumentLineCount() {
        let samples = ["", "\n", "a", "a\n", "a\nb", "a\nb\n", "a\n\nb\n", "a\nb\n\n", "one\ntwo\nthree"]
        for rawText in samples {
            let body = CodeStreamReconciler.canonicalBody(rawText)
            let document = CodeBlockDocument(text: body)
            #expect(
                MessageStacking.codeLineCount(forRawText: rawText) == document.lineCount,
                "rawText \(rawText.debugDescription)"
            )
        }
    }

    @Test func codeBlockHeightMatchesContainerFormula() {
        let metrics = MessageLayoutMetrics()
        let lineHeight = metrics.codeLineHeight
        // The container's historical formula: min(max(lh+16, n*lh+16), 300).
        for lineCount in [0, 1, 5, 100, 10_000] {
            let expected = min(
                max(lineHeight + 16, CGFloat(lineCount) * lineHeight + 16),
                metrics.maxCodeBlockHeight
            )
            let actual = MessageStacking.codeBlockHeight(
                lineCount: lineCount, lineHeight: lineHeight, metrics: metrics
            )
            #expect(actual == expected, "lineCount \(lineCount)")
        }
    }
}
