import Foundation
import Testing
@testable import ClaudeNativeCore

struct TranscriptContentTests {
    @Test func imageOnlySessionsRemainListedAndRestored() throws {
        let file = SessionHistoryTests.history.appending(path: "multimodal.jsonl")
        let heading = try #require(SessionHistory.readHeading(ofSessionFile: file))
        #expect(heading.firstPrompt == "Image attachment (image/webp)")
        let loaded = try SessionHistory.loadSession(fileURL: file)
        #expect(loaded.entries.first?.text == "Image attachment (image/webp)")
        #expect(loaded.entries.last?.text == "Review this report.\nDocument: Report (text/plain)\nThe build passed.\nDocument: Appendix (application/pdf)")
        #expect(!loaded.entries.contains { $0.text.contains("BINARY_MUST_NOT_APPEAR") || $0.output?.contains("BINARY_MUST_NOT_APPEAR") == true })
        // A session that never had typed text was previously absent from
        // the sidebar entirely, even when it had a saved custom title.
        let directory = try TemporaryFolder()
        let first = try #require(String(contentsOf: file, encoding: .utf8).split(separator: "\n").first)
        try String(first).write(to: directory.url.appending(path: "image-only.jsonl"), atomically: true, encoding: .utf8)
        #expect(SessionHistory.listSessions(inProjectDirectory: directory.url).map(\.title) == ["Image attachment (image/webp)"])
        try (String(first) + "\n" + #"{"type":"custom-title","customTitle":"Screenshot review"}"#)
            .write(to: directory.url.appending(path: "image-only.jsonl"), atomically: true, encoding: .utf8)
        #expect(SessionHistory.listSessions(inProjectDirectory: directory.url).map(\.title) == ["Screenshot review"])
    }

    @Test func everyToolResultIsAppliedLiveAndMatchesTheSavedSession() throws {
        let saved = try SessionHistoryTests.load("multimodal")
        let data = try Data(contentsOf: SessionHistoryTests.history.appending(path: "multimodal.jsonl"))
        var live = Transcript()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let value = try JSONValue.parse(Data(line))
            for event in try StreamEvent.readAll(value) { live.apply(event, at: nil) }
        }
        let tools = live.entries.filter { $0.toolInput != nil }
        #expect(tools.map(\.kind) == [.tool(name: "Read", status: .succeeded), .tool(name: "ToolSearch", status: .failed)])
        #expect(tools.map(\.output) == ["Screenshot follows.\nImage attachment (image/png)", "Tool reference: Read\nTool unavailable."])
        #expect(tools == saved.entries.filter { $0.toolInput != nil })
    }

    @Test func malformedResultsDoNotDiscardLaterValidResultsOrExposeSubagents() throws {
        let line = try JSONValue.parse(Data(#"{"type":"user","message":{"content":[{"type":"tool_result","content":"missing id"},{"type":"tool_result","tool_use_id":"ok","content":"done"}]}}"#.utf8))
        #expect(try StreamEvent.readAll(line) == [.toolResult(toolUseID: "ok", text: "done", isError: false)])
        var child = try #require(line.object)
        child["parent_tool_use_id"] = .string("agent")
        #expect(try StreamEvent.readAll(.object(child)).isEmpty)
    }

    @Test func mcpAndSearchContentKeepTheirTextAndDescribeBinaryContent() throws {
        let value = try JSONValue.parse(Data(#"[{"type":"resource","resource":{"uri":"file:///tmp/notes.txt","mimeType":"text/plain","text":"Remember the test."}},{"type":"resource_link","name":"Report","uri":"file:///tmp/report.pdf","mimeType":"application/pdf"},{"type":"audio","data":"BINARY_MUST_NOT_APPEAR","mimeType":"audio/wav"},{"type":"search_result","title":"Build notes","source":"https://example.com/notes","content":[{"type":"text","text":"All checks passed."}]},{"type":"future_media","data":"BINARY_MUST_NOT_APPEAR"}]"#.utf8))
        #expect(StreamEvent.text(of: value) == "Resource: file:///tmp/notes.txt (text/plain)\nRemember the test.\nResource link: Report (application/pdf)\nfile:///tmp/report.pdf\nAudio attachment (audio/wav)\nSearch result: Build notes\nAll checks passed.\nUnsupported content: future_media")
    }

    @Test func deeplyNestedContentAndLargeMetadataStayBounded() throws {
        var block: JSONValue = .object(["type": .string("text"), "text": .string("Deep text")])
        for _ in 0..<100 {
            block = .object(["type": .string("search_result"), "title": .string("Nested"), "content": .array([block])])
        }
        let result = StreamEvent.text(of: .array([block]))
        #expect(result.contains("Nested content omitted"))
        #expect(result.count < 1_000)
        let large: JSONValue = .array([.object(["type": .string("image"), "mimeType": .string(String(repeating: "x", count: 10_000))])])
        #expect(StreamEvent.text(of: large).count < 1_000)
    }

    @Test func injectedImageMessagesStayOutOfUserHistory() throws {
        let line = try JSONValue.parse(Data(#"{"type":"user","isMeta":true,"message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"hidden"}}]}}"#.utf8))
        #expect(SessionHistory.promptText(of: line) == nil)
    }
}
