// Copy into an archived revision for the historical audit; see docs/PERFORMANCE.md.
import Foundation
import Testing
@testable import ChatMarkdownCore

struct HistoricalBenchmarkTests {
    func sample(_ name: String, repeats: Int = 3, _ body: () -> Int) {
        var times: [Double] = []
        var checksum = 0
        for _ in 0..<repeats {
            let start = DispatchTime.now().uptimeNanoseconds
            checksum += body()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        times.sort()
        print("HISTPERF \(name) median_ms=\(times[times.count / 2]) min_ms=\(times[0]) checksum=\(checksum)")
        #expect(checksum > 0)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHAT_MARKDOWN_HISTORY_BENCHMARKS"] == "1")) func historicalCommonWorkloads() {
        for count in [800, 1600, 3200] {
            let chunks = (0..<count).map { "Paragraph \($0) with **bold** and a [link](https://example.com).\n\n" }
            sample("prose-stream-\(count)") {
                let assembler = StreamingMessageAssembler(messageID: MessageID("history"))
                for chunk in chunks { assembler.append(chunk) }
                return assembler.currentDocument.blocks.count
            }
            let source = chunks.joined()
            sample("full-oracle-\(count)", repeats: 9) { MarkdownConverter.blocks(from: source).count }
#if CHAT_MARKDOWN_DIRECT_PARSER
            sample("full-direct-\(count)", repeats: 9) { CmarkDirectParser.parsedBlocks(from: source).count }
#endif
        }
        for count in [2000, 4000, 8000] {
            let chunks = (0..<count).map { "let v\($0) = compute(\($0)) + 4\n" }
            sample("code-stream-\(count)") {
                let assembler = StreamingMessageAssembler(messageID: MessageID("history"))
                assembler.append("Intro.\n\n```swift\n")
                for chunk in chunks { assembler.append(chunk) }
                return assembler.fastCodePathCount
            }
        }
        for count in [500, 1000, 2000] {
            let chunks = (0..<count).map { "word\($0) " }
            sample("one-line-stream-\(count)") {
                let assembler = StreamingMessageAssembler(messageID: MessageID("history"))
                for chunk in chunks { assembler.append(chunk) }
                return assembler.currentDocument.blocks.count
            }
        }
    }
}
