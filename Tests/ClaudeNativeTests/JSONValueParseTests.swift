import Foundation
import Testing
@testable import ClaudeNativeCore

/// Every stream line and saved-session line goes through JSONValue.parse.
/// It must give exactly what decoding the Codable JSONValue gives, only
/// faster: the decoder tried Bool, Double, String and array before object,
/// so each object threw four errors first.
struct JSONValueParseTests {
    static func decoded(_ line: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: line) }

    static var fixtureLines: [Data] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.flatMap { file in
            ((try? Data(contentsOf: file)) ?? Data()).split(separator: 0x0A).map { Data($0) }
        }
    }

    @Test func everyCapturedLineParsesAsTheDecoderDoes() throws {
        let lines = Self.fixtureLines
        #expect(lines.count > 100)
        for line in lines {
            let (parsed, decoded) = (try JSONValue.parse(line), try Self.decoded(line))
            #expect(parsed == decoded, "\(Self.difference(parsed, decoded) ?? "?")")
        }
    }

    /// Where two values first differ, for a failure message.
    static func difference(_ a: JSONValue, _ b: JSONValue, at path: String = "") -> String? {
        switch (a, b) {
        case (.object(let x), .object(let y)):
            if Set(x.keys) != Set(y.keys) { return "\(path): keys \(Set(x.keys).symmetricDifference(Set(y.keys)))" }
            return x.keys.sorted().lazy.compactMap { difference(x[$0]!, y[$0]!, at: path + "." + $0) }.first
        case (.array(let x), .array(let y)):
            if x.count != y.count { return "\(path): \(x.count) vs \(y.count) items" }
            return zip(x, y).enumerated().lazy.compactMap { difference($1.0, $1.1, at: path + "[\($0)]") }.first
        default:
            return a == b ? nil : "\(path): \(String(describing: a).prefix(80)) vs \(String(describing: b).prefix(80))"
        }
    }

    @Test(arguments: [
        "true", "false", "0", "1", "-2.5", "1e3", "9007199254740993", "null", "\"é \\u00e9 \\n \\\" 🎉\"",
        "[]", "{}", "[true, 1, \"1\", null, {\"a\": [false, 0]}]", "{\"is_error\": false, \"count\": 1, \"ok\": true}",
    ])
    func edgeValuesParseAsTheDecoderDoes(text: String) throws {
        let line = Data(text.utf8)
        #expect(try JSONValue.parse(line) == Self.decoded(line))
    }

    @Test func malformedLinesStillThrow() {
        #expect(throws: (any Error).self) { try JSONValue.parse(Data("{\"a\": ".utf8)) }
        #expect(throws: (any Error).self) { try JSONValue.parse(Data()) }
    }

    /// Measured against the decoder on the same lines, so a busy machine
    /// slows both: 3.4 times faster on a real 92 MB session.
    @Test func parsingIsMuchFasterThanTheDecoder() throws {
        let lines = Array(repeating: Self.fixtureLines, count: 4).flatMap { $0 }
        let clock = ContinuousClock()
        let decoder = clock.measure { for line in lines { _ = try? Self.decoded(line) } }
        let parse = clock.measure { for line in lines { _ = try? JSONValue.parse(line) } }
        #expect(parse * 2 < decoder, "parse \(parse), decoder \(decoder)")
    }
}
