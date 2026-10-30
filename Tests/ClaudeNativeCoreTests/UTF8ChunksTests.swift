import Foundation
import Testing
@testable import ClaudeNativeCore

/// The terminal's output arrives in reads of whatever size; a character
/// split between two reads came out as two replacement characters, which
/// VoiceOver read aloud.
struct UTF8ChunksTests {
    static let text = "café 🙂 ls naïve 日本"

    @Test(arguments: 1...Array(UTF8ChunksTests.text.utf8).count)
    func aCharacterSplitBetweenReadsComesOutWhole(at split: Int) {
        let bytes = Array(Self.text.utf8)
        var chunks = UTF8Chunks()
        let out = chunks.decode(bytes[..<split]) + chunks.decode(bytes[split...])
        #expect(out == Self.text)
    }

    @Test func invalidBytesAreReplacedNotHeldBack() {
        var chunks = UTF8Chunks()
        #expect(chunks.decode([0x61, 0xFF, 0x62]) == "a\u{FFFD}b")
        // A stray continuation byte doesn't wait for more.
        #expect(chunks.decode([0x80]) == "\u{FFFD}")
    }
}
