import Foundation
import Testing
@testable import ClaudeNativeCore

struct PermissionWordingTests {
    @Test func explainsCommonToolsInPlainWords() {
        #expect(PermissionWording.explanation(toolName: "Bash") == "Claude wants to run a command.")
        #expect(PermissionWording.explanation(toolName: "Edit") == "Claude wants to change a file.")
        #expect(PermissionWording.explanation(toolName: "mcp__chrome-devtools__navigate") == "Claude wants to use navigate (chrome devtools).")
    }

    /// Real requests from the captures: the detail is the command or path
    /// alone, without the tool name repeated.
    @Test func detailDropsTheToolName() throws {
        for fixture in ["real_permission_allow", "real_permission_deny"] {
            let request = try #require(FixtureReplayTests.events(fixture).compactMap {
                if case .permissionRequest(let request) = $0 { request } else { nil }
            }.first)
            let detail = try #require(PermissionWording.detail(toolName: request.toolName, input: request.input))
            #expect(!detail.hasPrefix(request.toolName))
            #expect(detail.contains(".txt"))
        }
        #expect(PermissionWording.detail(toolName: "Bash", input: .object(["command": .string("touch a.txt")])) == "touch a.txt")
        #expect(PermissionWording.detail(toolName: "Bash", input: .object([:])) == nil)
    }

    /// The question names the action and its target, as the Claude app's
    /// does; a tool it can't word says "use" with the tool's name.
    @Test func questionNamesTheActionAndTarget() {
        func ask(_ tool: String, _ input: [String: JSONValue]) -> String {
            PermissionWording.question(toolName: tool, input: .object(input))
        }
        #expect(ask("Bash", ["command": .string("git status")]) == "Allow Claude to run git status?")
        #expect(ask("Bash", ["command": .string("cd a\nmake")]) == "Allow Claude to run cd a\u{2026}?")
        #expect(ask("Bash", ["command": .string(String(repeating: "x", count: 70))]) == "Allow Claude to run \(String(repeating: "x", count: 60))\u{2026}?")
        #expect(ask("Edit", ["file_path": .string("/Users/me/garden/Sources/App.swift")]) == "Allow Claude to edit App.swift?")
        #expect(ask("Write", ["file_path": .string("/tmp/a.txt")]) == "Allow Claude to write a.txt?")
        #expect(ask("WebFetch", ["url": .string("https://example.com/docs/page")]) == "Allow Claude to fetch example.com?")
        #expect(ask("mcp__chrome-devtools__navigate", [:]) == "Allow Claude to use navigate (chrome devtools)?")
        #expect(ask("Edit", [:]) == "Allow Claude to use Edit?")
        #expect(!PermissionWording.questionSaysTheAction(toolName: "Edit", input: .object([:])))
        #expect(PermissionWording.questionSaysTheAction(toolName: "Bash", input: .object(["command": .string("ls")])))
    }

    /// A real plan approval, as Claude sent it in Plan mode: the card says
    /// Claude proposed a plan, shows the plan, and answers Reject, Accept,
    /// or Accept and Allow Edits.
    @Test func planApprovalShowsThePlan() throws {
        let data = try Data(contentsOf: FixtureReplayTests.fixtures.appending(path: "real_exit_plan_mode_input.json"))
        let fixture = try JSONDecoder().decode(JSONValue.self, from: data)
        let toolName = try #require(fixture["toolName"]?.string)
        let input = try #require(fixture["input"])
        let request = PermissionRequest(requestID: "p1", toolName: toolName, input: input)
        #expect(request.isPlanApproval)
        #expect(PermissionWording.question(toolName: toolName, input: input) == "Claude proposed a plan")
        #expect(PermissionWording.questionSaysTheAction(toolName: toolName, input: input))
        let detail = try #require(PermissionWording.detail(toolName: toolName, input: input))
        #expect(detail.hasPrefix("# Plan: add hello.txt"))
        #expect(detail.contains("## Steps"))
        #expect(PermissionWording.answerTitles(toolName: toolName) == ("Reject", "Accept"))
        #expect(request.suggestions.map(\.title) == ["Accept and Allow Edits"])
        #expect(request.suggestions.first?.raw["mode"]?.string == "acceptEdits")
        #expect(PermissionWording.answerTitles(toolName: "Bash") == ("Deny", "Allow Once"))
    }

    /// Revise sends the plan back with the user's note as the deny message
    /// Claude reads; an empty note still asks for a revision.
    @Test func revisingAPlanSendsTheNote() throws {
        let request = PermissionRequest(requestID: "p1", toolName: "ExitPlanMode", input: .object(["plan": .string("# Plan")]), toolUseID: "t1")
        let note = PermissionWording.revisionMessage("  Use a shell script instead.\n")
        let response = ClaudeCLI.permissionResponse(to: request, allow: false, denialMessage: note)
        #expect(response["response"]?["response"]?["behavior"] == .string("deny"))
        #expect(response["response"]?["response"]?["message"] == .string("The user wants the plan revised before you start. What should change: Use a shell script instead."))
        #expect(PermissionWording.revisionMessage(" ").hasSuffix("Ask them what should change."))
        #expect(ClaudeCLI.permissionResponse(to: request, allow: false)["response"]?["response"]?["message"] == .string("The user denied this."))
    }
}
