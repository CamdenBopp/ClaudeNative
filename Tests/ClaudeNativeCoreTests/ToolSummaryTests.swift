import Foundation
import Testing
@testable import ClaudeNativeCore

struct ToolSummaryTests {
    @Test func pathsInsideTheWorkingFolderReadRelative() {
        let base = URL(fileURLWithPath: "/Users/x/Project")
        #expect(ToolSummary.shorten("Write: /Users/x/Project/Sources/App.swift", relativeTo: base) == "Write: Sources/App.swift")
    }

    @Test func pathsOutsideTheWorkingFolderStayWhole() {
        let base = URL(fileURLWithPath: "/Users/x/Project")
        #expect(ToolSummary.shorten("Read: /Users/x/Other/notes.txt", relativeTo: base) == "Read: /Users/x/Other/notes.txt")
        #expect(ToolSummary.shorten("Read: /Users/x/ProjectB/a.txt", relativeTo: base) == "Read: /Users/x/ProjectB/a.txt")
    }

    @Test func privateTempAliasesAreTreatedAsTheSameFolder() {
        let base = URL(fileURLWithPath: "/private/tmp/work")
        #expect(ToolSummary.shorten("Write: /tmp/work/hello.txt", relativeTo: base) == "Write: hello.txt")
        #expect(ToolSummary.shorten("Write: /private/tmp/work/hello.txt", relativeTo: URL(fileURLWithPath: "/tmp/work")) == "Write: hello.txt")
    }
}

/// MCP tool names as VoiceOver hears them. The names come verbatim from a
/// real system/init line (CLI 2.1.308) with two local stdio MCP servers
/// configured as "chrome-devtools" and "My Server.v2"; the CLI keeps hyphens
/// and turns the space and dot into underscores.
struct ToolSpokenNameTests {
    static func initTools() throws -> [String] {
        let line = try #require(FixtureReplayTests.lines("real_init_mcp_tools").first).msg
        return try #require(line["tools"]?.array).compactMap(\.string)
    }

    @Test func mcpToolsReadAsToolThenServerInWords() throws {
        let mcp = try Self.initTools().filter { $0.hasPrefix("mcp__") }
        #expect(mcp.map(ToolSummary.spokenName) == [
            "get page text (chrome devtools)",
            "navigate (chrome devtools)",
            "read page (chrome devtools)",
            "tabs context mcp (chrome devtools)",
            "get page text (My Server v2)",
            "navigate (My Server v2)",
            "read page (My Server v2)",
            "tabs context mcp (My Server v2)",
        ])
    }

    @Test func builtInToolsKeepTheirNames() throws {
        let builtIns = try Self.initTools().filter { !$0.hasPrefix("mcp__") }
        #expect(builtIns.contains("Bash"))
        #expect(builtIns.map(ToolSummary.spokenName) == builtIns)
    }

    @Test func namesThatOnlyLookLikeMCPStayWhole() {
        for name in ["mcp__", "mcp__server", "mcp__server__", "mcp____navigate", "mcp_x__y"] {
            #expect(ToolSummary.spokenName(name) == name)
        }
    }

    @Test func toolRowsAndPromptSummariesUseTheSpokenName() {
        let input: JSONValue = .object(["url": .string("https://example.com")])
        #expect(ToolSummary.describe(name: "mcp__chrome-devtools__navigate", input: input)
            == "navigate (chrome devtools): https://example.com")

        var transcript = Transcript()
        transcript.apply(.assistantMessage(messageID: "msg_1", blocks: [
            .toolUse(id: "toolu_1", name: "mcp__chrome-devtools__navigate", input: input),
        ]))
        let row = transcript.entries[0]
        #expect(row.kind == .tool(name: "mcp__chrome-devtools__navigate", status: .running))
        #expect(RowWording.accessibilityValue(for: row, base: nil, isMarked: false)
            == "Tool, running: navigate (chrome devtools): https://example.com")
    }
}
