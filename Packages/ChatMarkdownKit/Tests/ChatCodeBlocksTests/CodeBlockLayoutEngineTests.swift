import CoreGraphics
import Testing
@testable import ChatCodeBlocks

struct CodeBlockLayoutEngineTests {
    @Test func metricsAreUniformAndPositive() {
        let document = CodeBlockDocument(text: "line one\nline two\nline three")
        let engine = CodeBlockLayoutEngine(document: document)
        #expect(engine.lineHeight > 0)
        #expect(engine.ascent > 0)
        #expect(engine.contentSize.height == CGFloat(3) * engine.lineHeight)
        #expect(engine.contentSize.width > 0)
        #expect(engine.yOrigin(forRow: 2) == 2 * engine.lineHeight)
    }

    @Test func rowRangeMapsViewportToRows() {
        let document = CodeBlockDocument(text: (0..<1000).map { "line \($0)" }.joined(separator: "\n"))
        let engine = CodeBlockLayoutEngine(document: document)
        let h = engine.lineHeight

        let top = engine.rowRange(intersecting: CGRect(x: 0, y: 0, width: 300, height: h * 10), overscan: 0)
        #expect(top == 0..<10)

        let middle = engine.rowRange(intersecting: CGRect(x: 0, y: h * 500, width: 300, height: h * 10), overscan: 5)
        #expect(middle == 495..<515)

        let past = engine.rowRange(intersecting: CGRect(x: 0, y: h * 2000, width: 300, height: 100), overscan: 0)
        #expect(past.isEmpty)
    }

    @Test func layoutIsCachedPerRow() {
        let document = CodeBlockDocument(text: "alpha\nbeta")
        let engine = CodeBlockLayoutEngine(document: document)
        let first = engine.layout(row: 0)
        let second = engine.layout(row: 0)
        #expect(first.line === second.line)
        #expect(engine.cachedLineCount == 1)
    }

    @Test func appendInvalidatesOnlyTheModifiedRow() {
        let document = CodeBlockDocument(text: "let x")
        let engine = CodeBlockLayoutEngine(document: document)
        let before = engine.layout(row: 0)

        let delta = document.append(" = 1\nnext line")
        engine.apply(delta)

        let after = engine.layout(row: 0)
        #expect(before.line !== after.line)
        #expect(after.width > before.width)
        #expect(engine.lineCount == 2)
    }

    @Test func widthEstimateTracksLongestLine() {
        let document = CodeBlockDocument(text: "short")
        let engine = CodeBlockLayoutEngine(document: document)
        let narrow = engine.contentSize.width

        let delta = document.append("\n" + String(repeating: "x", count: 200))
        engine.apply(delta)
        #expect(engine.contentSize.width > narrow * 10)
    }

    @Test func tenThousandRowsOnlyLayOutTheViewport() {
        let document = CodeBlockDocument()
        for index in 0..<10_000 {
            document.append("assembly line \(index) mov r\(index % 16), r\(index % 7)\n")
        }
        let engine = CodeBlockLayoutEngine(document: document)

        // Simulate scrolling through 5 viewport positions.
        for page in 0..<5 {
            let rect = CGRect(x: 0, y: CGFloat(page * 2000) * engine.lineHeight, width: 400, height: 800)
            for row in engine.rowRange(intersecting: rect, overscan: 8) {
                _ = engine.layout(row: row)
            }
        }
        // Resident CTLines stay bounded by the cache budget, far below the
        // document size.
        #expect(engine.cachedLineCount < 2_000)
        #expect(engine.lineCount == 10_001)
    }
}
