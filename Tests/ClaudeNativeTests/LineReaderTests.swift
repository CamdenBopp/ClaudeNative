import Foundation
import Testing
@testable import ClaudeNativeCore

/// Session files are read a line at a time. Lines come back exactly,
/// including ones that straddle the reader's 1 MB chunks, an empty line,
/// and a last line with no newline after it.
struct LineReaderTests {
    static func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lines-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        return url
    }

    static func lines(of url: URL) throws -> [Data] {
        let reader = try #require(LineReader(url: url))
        var lines: [Data] = []
        while let line = reader.next() { lines.append(line) }
        return lines
    }

    @Test func linesComeBackExactlyAcrossChunks() throws {
        let long = Data(repeating: UInt8(ascii: "a"), count: (1 << 20) + 17)
        let expected = [Data("first".utf8), long, Data(), Data("{\"type\":\"user\"}".utf8), Data("last".utf8)]
        let url = try Self.file(Data(expected.map { $0 }.joined(separator: Data([0x0A]))))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Self.lines(of: url) == expected)
    }

    /// Reopening a long session read its file one byte at a time through
    /// generic Data indexing: 0.92 s of a 92 MB session's 2.2 s load
    /// (debug build). 64 MB of typical-length lines must split well inside
    /// that rate.
    @Test func splittingALargeFileIsFast() throws {
        let line = Data((String(repeating: "x", count: 4000) + "\n").utf8)
        var data = Data(capacity: 64 << 20)
        while data.count < 64 << 20 { data.append(line) }
        let url = try Self.file(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(LineReader(url: url))
        var count = 0
        let elapsed = ContinuousClock().measure { while reader.next() != nil { count += 1 } }
        #expect(count == data.count / line.count)
        #expect(elapsed < .milliseconds(250), "took \(elapsed)")
    }
}
