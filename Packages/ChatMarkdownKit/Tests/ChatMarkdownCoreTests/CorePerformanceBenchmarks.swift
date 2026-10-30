import Foundation
import Testing
@testable import ChatMarkdownCore

/// Opt-in wall-clock diagnostics. Normal test runs use deterministic work and
/// semantic assertions instead of comparing timing on different machines.
@Suite(.serialized)
struct CorePerformanceBenchmarks {
    private static let enabled = ProcessInfo.processInfo.environment["CHAT_MARKDOWN_BENCHMARKS"] == "1"

    private func report(_ name: String, samples: [Double]) {
        let sorted = samples.sorted()
        print("BENCHMARK \(name): median=\(String(format: "%.3f", sorted[sorted.count / 2])) ms samples=\(sorted.map { String(format: "%.3f", $0) }.joined(separator: ","))")
    }

    private func timed(_ action: () -> Void) -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        action()
        let components = start.duration(to: clock.now).components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    @Test(.enabled(if: enabled)) func completeDocumentParsing() {
        let large = (0..<5_000).map { "Paragraph \($0) contains **bold**, *italic*, [a link](https://example.com) and `code`, with Unicode café 😀.\n\n" }.joined()
        let repeated = Array(repeating: "Repeated paragraph.\n\n", count: 8_000).joined()
        let dense = (0..<2_000).map { "`value\($0)`" }.joined(separator: " ")
        let softBreaks = (0..<5_000).map { "Line \($0) has words and Unicode café 😀." }.joined(separator: "\n")
        let longSoftBreaks = (0..<20_000).map { "Line \($0) has words and Unicode café 😀." }.joined(separator: "\n")
        for (name, source, count) in [("parse-rich-5000", large, 5_000), ("parse-duplicate-8000", repeated, 8_000), ("parse-code-spans-2000", dense, 1), ("parse-softbreak-5000", softBreaks, 1), ("parse-softbreak-20000", longSoftBreaks, 1)] {
            _ = DocumentMarkdownParser.parse(source)
            var samples: [Double] = []
            for _ in 0..<7 {
                var result: ParsedMarkdownDocument?
                samples.append(timed { result = DocumentMarkdownParser.parse(source) })
                #expect(result?.document.blocks.count == count)
            }
            report(name, samples: samples)
        }
    }

    @Test(.enabled(if: enabled)) func completeDocumentSessions() async {
        let repeated = Array(repeating: "Repeated paragraph.\n\n", count: 8_000).joined()
        let distinct = (0..<8_000).map { "Paragraph \($0).\n\n" }.joined()
        for (name, source) in [("session-duplicate-8000", repeated), ("session-distinct-8000", distinct)] {
            let session = MarkdownDocumentSession(id: .init(name))
            let initial = await session.replaceSource(source)
            var samples: [Double] = []
            let clock = ContinuousClock()
            for index in 0..<7 {
                let start = clock.now
                let result = await session.replaceSource("# Revision \(index)\n\n" + source)
                let components = start.duration(to: clock.now).components
                samples.append(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15)
                #expect(result.document.blocks.last?.id == initial.document.blocks.last?.id)
            }
            report(name, samples: samples)
        }
    }

    @Test(.enabled(if: enabled)) func streaming() {
        for (name, count) in [("stream-prose-1000", 1_000), ("stream-prose-5000", 5_000)] {
            var samples: [Double] = []
            for _ in 0..<5 {
                let assembler = StreamingMessageAssembler(messageID: .init(name))
                samples.append(timed {
                    for index in 0..<count { assembler.append("Paragraph \(index) has a sentence of content.\n\n") }
                })
                #expect(assembler.currentDocument.blocks.count == count)
            }
            report(name, samples: samples)
        }
        for (name, count) in [("stream-code-1000", 1_000), ("stream-code-5000", 5_000), ("stream-code-10000", 10_000)] {
            var samples: [Double] = []
            for _ in 0..<5 {
                let assembler = StreamingMessageAssembler(messageID: .init(name))
                assembler.append("```swift\n")
                samples.append(timed {
                    for index in 0..<count { assembler.append("let value\(index) = compute(\(index)) + offset\n") }
                })
                #expect(assembler.fastCodePathCount == count)
            }
            report(name, samples: samples)
        }
    }
}
