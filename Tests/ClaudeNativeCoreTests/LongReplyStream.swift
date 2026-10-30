import Foundation
import ClaudeNativeCore

/// A long Claude reply streamed the way the CLI sends it: stdout lines shaped
/// like Tests/Fixtures/real_text_reply.jsonl (message_start, text deltas of a
/// few words each, content_block_stop, the final assistant line, result),
/// read through `StreamEvent.read` as the app reads them.
enum LongReplyStream {
    static let messageID = "msg_long_reply"

    /// Markdown with the mix a long coding answer has: headings, prose,
    /// lists, and Swift and shell code blocks. `lines` counts lines of text.
    static func reply(lines: Int) -> String {
        let section = [
            "## Step %d: wire up the cache",
            "",
            "The view asks for a value, and the cache answers from memory when it can.",
            "Otherwise it loads from disk, which is **slower** but keeps `state` honest.",
            "",
            "- Read the key from the request",
            "- Look it up, falling back to the loader",
            "- Store the result with its `expiry`",
            "",
            "```swift",
            "struct Cache<Key: Hashable, Value> {",
            "    private var storage: [Key: (value: Value, expiry: Date)] = [:]",
            "",
            "    mutating func value(for key: Key, now: Date = .now, load: () throws -> Value) rethrows -> Value {",
            "        if let hit = storage[key], hit.expiry > now { return hit.value }",
            "        let fresh = try load()",
            "        storage[key] = (fresh, now.addingTimeInterval(60))",
            "        return fresh",
            "    }",
            "}",
            "```",
            "",
            "Run it once to check:",
            "",
            "```sh",
            "swift test --filter CacheTests",
            "```",
            "",
        ]
        var out: [String] = []
        var step = 1
        while out.count < lines {
            for line in section where out.count < lines {
                out.append(line.contains("%d") ? String(format: line, step) : line)
            }
            step += 1
        }
        // A reply that ends mid-fence would leave the parser's fence open.
        if out.filter({ $0.hasPrefix("```") }).count % 2 == 1 { out.append("```") }
        return out.joined(separator: "\n")
    }

    /// The reply cut into deltas of about `size` characters.
    static func deltas(of text: String, size: Int = 20) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            pieces.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return pieces
    }

    /// The stdout lines for one turn that streams `text`, as JSON.
    static func stdoutLines(streaming text: String, size: Int = 20) -> [JSONValue] {
        func streamEvent(_ event: JSONValue) -> JSONValue {
            .object(["type": .string("stream_event"), "event": event, "session_id": .string("bench")])
        }
        var lines: [JSONValue] = [
            streamEvent(.object([
                "type": .string("message_start"),
                "message": .object(["id": .string(messageID), "role": .string("assistant"), "content": .array([])]),
            ])),
            streamEvent(.object([
                "type": .string("content_block_start"), "index": .number(0),
                "content_block": .object(["type": .string("text"), "text": .string("")]),
            ])),
        ]
        for piece in deltas(of: text, size: size) {
            lines.append(streamEvent(.object([
                "type": .string("content_block_delta"), "index": .number(0),
                "delta": .object(["type": .string("text_delta"), "text": .string(piece)]),
            ])))
        }
        lines.append(streamEvent(.object(["type": .string("content_block_stop"), "index": .number(0)])))
        lines.append(.object([
            "type": .string("assistant"),
            "message": .object([
                "id": .string(messageID),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]),
        ]))
        lines.append(.object([
            "type": .string("result"), "subtype": .string("success"),
            "is_error": .bool(false), "result": .string(text),
        ]))
        return lines
    }

    /// The events the app's reader makes of those lines.
    static func events(streaming text: String, size: Int = 20) throws -> [StreamEvent] {
        try stdoutLines(streaming: text, size: size).compactMap { try StreamEvent.read($0) }
    }
}
