import Foundation
import Testing
@testable import ChatCodeBlocks

struct CodePerformanceBenchmarks {
    private static let enabled = ProcessInfo.processInfo.environment["CHAT_MARKDOWN_BENCHMARKS"] == "1"

    private func report(_ name: String, action: () -> Void) {
        var samples: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<5 {
            let start = clock.now
            action()
            let components = start.duration(to: clock.now).components
            samples.append(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15)
        }
        let sorted = samples.sorted()
        print("BENCHMARK \(name): median=\(String(format: "%.3f", sorted[sorted.count / 2])) ms samples=\(sorted.map { String(format: "%.3f", $0) }.joined(separator: ","))")
    }

    @Test(.enabled(if: enabled)) func codeStorageAndSnapshots() {
        report("code-storage-10000") {
            let document = CodeBlockDocument()
            for index in 0..<10_000 { document.append("let value\(index) = compute(\(index)) + offset\n") }
            #expect(document.lineCount == 10_001)
        }
        for count in [1_000, 3_000] {
            let snapshots = (0..<count).reduce(into: [String]()) { snapshots, index in
                snapshots.append((snapshots.last ?? "") + "let value\(index) = compute(\(index)) + offset\n")
            }
            report("code-snapshots-\(count)") {
                let document = CodeBlockDocument()
                var applied = ""
                for snapshot in snapshots {
                    _ = CodeStreamReconciler.applySnapshot(rawText: snapshot, appliedBody: &applied, document: document)
                }
                #expect(document.lineCount == count)
            }
            // The previous implementation, retained only inside this opt-in
            // diagnostic so both algorithms use the same snapshots/process.
            // Correctness parity is covered separately by Unicode tests.
            report("code-snapshots-previous-algorithm-\(count)") {
                let document = CodeBlockDocument()
                var applied = ""
                for snapshot in snapshots {
                    let body = CodeStreamReconciler.canonicalBody(snapshot)
                    guard body.hasPrefix(applied) else { Issue.record("Expected append snapshot"); return }
                    let suffix = String(body.dropFirst(applied.count))
                    applied = body
                    document.append(suffix)
                }
                #expect(document.lineCount == count)
            }
        }
    }
}
