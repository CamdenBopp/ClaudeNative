import Testing
@testable import ClaudeNativeCore

struct ChatLineBreaksTests {
    /// The shape of a real reply that ran together: "1 1 2 4 3 9 ...".
    @Test func singleNewlinesBecomeHardBreaks() {
        #expect(ChatLineBreaks.hardened("1 1\n2 4\n3 9") == "1 1  \n2 4  \n3 9")
    }

    @Test func paragraphBreaksAndExistingHardBreaksAreLeftAlone() {
        #expect(ChatLineBreaks.hardened("a\n\nb") == "a  \n\nb")
        #expect(ChatLineBreaks.hardened("a  \nb\\\nc") == "a  \nb\\\nc")
    }

    @Test func codeFencesKeepTheirLinesExactly() {
        let text = "Run:\n```swift\nlet x = 1\nlet y = 2\n```\nDone\nnow"
        #expect(ChatLineBreaks.hardened(text) == "Run:  \n```swift\nlet x = 1\nlet y = 2\n```\nDone  \nnow")
    }

    @Test func aShorterOrDifferentMarkDoesNotCloseTheFence() {
        let text = "````\n```\ninside\n~~~\n````\nafter\nx"
        #expect(ChatLineBreaks.hardened(text) == "````\n```\ninside\n~~~\n````\nafter  \nx")
    }

    /// The streaming parser appends only the new tail, so every result must
    /// extend the previous one.
    @Test func growingTextOnlyGrowsAtTheEnd() {
        let full = "Plan:\n- one\n- two\n```\ncode\n```\nend line\nlast"
        var previous = ""
        for count in 0...full.count {
            let current = ChatLineBreaks.hardened(String(full.prefix(count)))
            #expect(current.hasPrefix(previous), "not a prefix at \(count)")
            previous = current
        }
    }

    // MARK: Streaming

    /// `hardened` as it was before it streamed: split the whole text on
    /// newlines and walk every line. Kept here as the oracle the stream must
    /// match byte for byte.
    static func wholeTextHardened(_ text: String) -> String {
        var result = ""
        var fence: Substring?
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        let tail = lines.popLast() ?? ""
        for line in lines {
            let marker = ChatLineBreaks.fenceMarker(line)
            if let open = fence {
                if let marker, marker.first == open.first, marker.count >= open.count { fence = nil }
                result += line + "\n"
            } else if let marker {
                fence = marker
                result += line + "\n"
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasSuffix("  ") || line.hasSuffix("\\") {
                result += line + "\n"
            } else {
                result += line + "  \n"
            }
        }
        return result + tail
    }

    /// Fences, tildes, indents, existing breaks, blank lines, Windows line
    /// ends and non-ASCII text, on top of a long realistic reply.
    static let awkward = [
        "Plan:\n- one\n- two\n```\ncode\n```\nend line\nlast",
        "a\r\nb\nc\r\n\r\nd\n```\r\nx\n```\ny",
        "   ```swift\nlet x = 1\n    ```\nstill code\n   ```\nout\n",
        "~~~~\n~~~\nin\n````\nstill in\n~~~~~\nout\n",
        "trailing  \nslash\\\n \t\nnaïve café ✓ 🧪 e\u{301}\nend",
        LongReplyStream.reply(lines: 150),
    ]

    @Test(arguments: [1, 2, 3, 7, 20, 64])
    func streamingMatchesTheWholeTextAtEveryPiece(size: Int) {
        for text in Self.awkward {
            var stream = ChatLineBreaks.Stream()
            var joined = ""
            var source = ""
            for piece in LongReplyStream.deltas(of: text, size: size) {
                source += piece
                joined += stream.append(piece)
                guard joined == Self.wholeTextHardened(source) else {
                    Issue.record("differs after \(source.utf8.count) bytes, piece size \(size)")
                    break
                }
            }
            #expect(joined == Self.wholeTextHardened(text))
        }
    }

    /// Deltas can split "\r\n" between them. It is one Character, so it must
    /// not end a line in either case.
    @Test func carriageReturnAndNewlineSplitAcrossPieces() {
        var stream = ChatLineBreaks.Stream()
        let joined = stream.append("one\r") + stream.append("\ntwo\n") + stream.append("three")
        #expect(joined == Self.wholeTextHardened("one\r\ntwo\nthree"))
        #expect(joined == "one\r\ntwo  \nthree")
    }

    /// Linear work: each byte is looked at once as it arrives and once more
    /// when its line ends. Hardening the whole reply after every delta looked
    /// at about bytes squared over twice the delta size (about 480 million
    /// for this reply).
    @Test(.timeLimit(.minutes(1)))
    func fiveThousandLineReplyHardensInLinearWork() {
        let text = LongReplyStream.reply(lines: 5_000)
        let pieces = LongReplyStream.deltas(of: text, size: 20)
        var stream = ChatLineBreaks.Stream()
        var joined = ""
        let elapsed = ContinuousClock().measure {
            for piece in pieces { joined += stream.append(piece) }
        }
        #expect(joined == ChatLineBreaks.hardened(text))
        #expect(
            stream.scannedUTF8 <= 2 * text.utf8.count,
            "scanned \(stream.scannedUTF8) bytes for a \(text.utf8.count)-byte reply"
        )
        // Measured at about 20 ms; the bound only catches a return to
        // quadratic work.
        #expect(elapsed < .seconds(1))
    }
}
