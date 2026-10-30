import Foundation
import Testing
@testable import ClaudeNativeCore

/// Replays CLI output captured in Tests/Fixtures (see docs/protocol.md)
/// through the parser and transcript, exactly as the app consumes it.
struct FixtureReplayTests {
    struct Line: Decodable {
        let dir: String
        let msg: JSONValue
    }

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures")

    static func lines(_ name: String) throws -> [Line] {
        let text = try String(contentsOf: fixtures.appending(path: "\(name).jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try JSONDecoder().decode(Line.self, from: Data($0.utf8))
        }
    }

    /// Every stdout line as the app's parser reads it.
    static func events(_ name: String) throws -> [StreamEvent] {
        try lines(name).filter { $0.dir == "stdout" }.compactMap {
            try StreamEvent.read(JSONValue.parse($0.msg.line()))
        }
    }

    static func replay(_ name: String, userText: String = "prompt") throws -> Transcript {
        var transcript = Transcript()
        transcript.appendUser(userText)
        for event in try events(name) { transcript.apply(event) }
        return transcript
    }

    /// The text the CLI's final `assistant` lines carry for each message id.
    static func finalAssistantText(_ name: String) throws -> [String: String] {
        var texts: [String: String] = [:]
        for line in try lines(name) where line.dir == "stdout" && line.msg["type"]?.string == "assistant" {
            guard let id = line.msg["message"]?["id"]?.string else { continue }
            for block in line.msg["message"]?["content"]?.array ?? [] {
                if let text = block["text"]?.string { texts[id, default: ""] += text }
            }
        }
        return texts
    }

    /// A subagent's own lines (its prompt, its tool calls) carry the
    /// Agent call's id as parent_tool_use_id. They're the Agent row's work,
    /// not the main conversation's: shown, its Glob read as a tool Claude
    /// ran, and the reopened session (which leaves them out) looked
    /// different. Captured from CLI 2.x with one general-purpose subagent.
    @Test func aSubagentsLinesStayInsideItsAgentRow() throws {
        let transcript = try Self.replay("real_subagent", userText: "Use the Task tool…")
        let kinds = transcript.entries.map { entry -> String in
            switch entry.kind {
            case .tool(let name, _): "tool:" + name
            default: "\(entry.kind)".components(separatedBy: "(").first ?? ""
            }
        }
        #expect(kinds == ["user", "thinking", "tool:Agent", "assistant"])
    }

    @Test(arguments: [
        "text_reply", "permission_allow", "permission_deny", "interrupt", "multi_turn", "resume",
        "probe_allow_edit", "probe_allow_noinput", "probe_control_misc", "probe_deny_interrupt",
        "probe_error_resp", "probe_minimal_user", "probe_queue", "api_auth_error",
        // Real-model twins, captured against the live API (docs/protocol.md).
        "real_text_reply", "real_permission_allow", "real_permission_deny", "real_interrupt",
        "real_ask_user_question", "real_interrupt_running_tool", "real_stop_pending_permission",
        "real_two_models", "real_plan_accept", "real_background_prompt",
    ])
    func everyLineParsesWithoutDiagnostics(fixture: String) throws {
        let transcript = try Self.replay(fixture)
        #expect(transcript.diagnostics == [])
    }

    /// An API error arrives twice: as an assistant line the CLI made up
    /// (model "<synthetic>", is_api_error_message) and as the error result.
    /// VoiceOver read it as Claude's reply, then again as the notice.
    @Test func anAPIErrorIsOneNoticeNotAReply() throws {
        let transcript = try Self.replay("api_auth_error")
        #expect(transcript.entries.filter { $0.kind == .assistant }.isEmpty)
        let notices = transcript.entries.filter { $0.kind == .notice }.map(\.text)
        #expect(notices.count == 1)
        #expect(notices.first?.hasPrefix("Error: Failed to authenticate") == true, "\(notices)")
    }

    @Test(arguments: ["text_reply", "real_text_reply"])
    func streamedTextMatchesFinalMessageWithoutDuplication(fixture: String) throws {
        let transcript = try Self.replay(fixture)
        let expected = try Self.finalAssistantText(fixture)
        let assistantRows = transcript.entries.filter { $0.kind == .assistant }
        #expect(assistantRows.count == expected.count)
        for row in assistantRows {
            let messageID = String(row.id.dropFirst("assistant:".count))
            #expect(row.text == expected[messageID])
        }
    }

    @Test(arguments: ["permission_allow", "real_permission_allow"])
    func allowedWriteShowsOneToolRowThatSucceeded(fixture: String) throws {
        let events = try Self.events(fixture)
        let request = try #require(events.compactMap { event -> PermissionRequest? in
            if case .permissionRequest(let request) = event { return request }
            return nil
        }.first)
        #expect(request.toolName == "Write")
        #expect(request.toolUseID != nil)

        let tools = try Self.replay(fixture).entries.filter {
            if case .tool = $0.kind { return true }
            return false
        }
        #expect(tools.count == 1)
        #expect(tools.first?.kind == .tool(name: "Write", status: .succeeded))
        #expect(tools.first?.text.hasPrefix("Write: ") == true)
    }

    @Test(arguments: ["permission_deny", "real_permission_deny"])
    func deniedWriteShowsToolRowThatFailed(fixture: String) throws {
        let tools = try Self.replay(fixture).entries.filter {
            if case .tool = $0.kind { return true }
            return false
        }
        #expect(tools.map(\.kind) == [.tool(name: "Write", status: .failed)])
    }

    @Test(arguments: ["permission_allow", "real_permission_allow"])
    func permissionResponseMatchesWhatTheCLIAccepted(fixture: String) throws {
        // The allow line the capture sent, which the CLI acted on.
        let sent = try #require(Self.lines(fixture).first {
            $0.dir == "stdin" && $0.msg["type"]?.string == "control_response"
        }).msg
        let requestLine = try #require(Self.lines(fixture).first {
            $0.dir == "stdout" && $0.msg["type"]?.string == "control_request"
                && $0.msg["request"]?["subtype"]?.string == "can_use_tool"
        }).msg
        guard case .permissionRequest(let request)? = try StreamEvent.read(requestLine) else {
            Issue.record("capture has no can_use_tool request")
            return
        }
        let ours = ClaudeCLI.permissionResponse(to: request, allow: true)
        #expect(ours["response"]?["request_id"] == sent["response"]?["request_id"])
        #expect(ours["response"]?["response"]?["behavior"] == .string("allow"))
        #expect(ours["response"]?["response"]?["toolUseID"] == sent["response"]?["response"]?["toolUseID"])
    }

    @Test(arguments: ["permission_deny", "real_permission_deny"])
    func denyResponseHasTheShapeTheCLIAccepted(fixture: String) throws {
        let sent = try #require(Self.lines(fixture).first {
            $0.dir == "stdin" && $0.msg["type"]?.string == "control_response"
        }).msg
        let requestLine = try #require(Self.lines(fixture).first {
            $0.dir == "stdout" && $0.msg["type"]?.string == "control_request"
                && $0.msg["request"]?["subtype"]?.string == "can_use_tool"
        }).msg
        guard case .permissionRequest(let request)? = try StreamEvent.read(requestLine) else {
            Issue.record("capture has no can_use_tool request")
            return
        }
        let ours = ClaudeCLI.permissionResponse(to: request, allow: false)
        #expect(ours["response"]?["request_id"] == sent["response"]?["request_id"])
        #expect(ours["response"]?["response"]?["behavior"] == .string("deny"))
        #expect(ours["response"]?["response"]?["toolUseID"] == sent["response"]?["response"]?["toolUseID"])
        // Same keys as the deny the CLI acted on; the message wording is ours to pick.
        let ourKeys = ours["response"]?["response"]?.object.map { Set($0.keys) }
        let sentKeys = sent["response"]?["response"]?.object.map { Set($0.keys) }
        #expect(ourKeys != nil)
        #expect(ourKeys == sentKeys)
    }

    @Test(arguments: ["interrupt", "probe_deny_interrupt", "real_interrupt"])
    func userStopEndsTheTurnAsStoppedNotFailed(fixture: String) throws {
        let events = try Self.events(fixture)
        #expect(events.last == .turnStopped)
        let transcript = try Self.replay(fixture)
        #expect(transcript.entries.last?.kind == .notice)
        #expect(transcript.entries.last?.text == "Stopped.")
        #expect(!transcript.entries.contains { $0.text.hasPrefix("Error") || $0.text.contains("ended with an error") })
    }

    /// Stop pressed while Bash runs `sleep 20` in the foreground. The CLI
    /// itself answers the cut-off call with an is_error tool_result before
    /// the aborted result, so the row settles as failed and nothing is left
    /// "running".
    @Test func stopDuringARunningToolSettlesItsRowFromTheCLIsErrorResult() throws {
        let events = try Self.events("real_interrupt_running_tool")
        let toolID = "toolu_011Fn3w8wsfDiXkMPmBdz3fr"
        let results = events.compactMap { event -> Bool? in
            if case .toolResult(toolID, _, let isError) = event { return isError }
            return nil
        }
        #expect(results == [true])
        #expect(events.last == .turnStopped)

        let transcript = try Self.replay("real_interrupt_running_tool")
        let row = try #require(transcript.entry(id: "tool:\(toolID)"))
        #expect(row.kind == .tool(name: "Bash", status: .failed))
        #expect(RowWording.spokenTitle(of: row) == "Tool, failed")
        #expect(transcript.entries.last?.text == "Stopped.")
    }
}

struct ChildEnvironmentTests {
    @Test func dropsHostSessionVariablesAndKeepsTheRest() {
        let child = ClaudeCLI.childEnvironment([
            "PATH": "/usr/bin",
            "HOME": "/Users/x",
            "ANTHROPIC_API_KEY": "kept-on-purpose",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:1",
            "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
            "CLAUDECODE": "1",
            "CLAUDE_PID": "123",
            "CLAUDE_NATIVE_CLI": "/opt/claude",
        ])
        #expect(child == [
            "PATH": "/usr/bin", "HOME": "/Users/x", "ANTHROPIC_API_KEY": "kept-on-purpose",
            "CLAUDE_NATIVE_CLI": "/opt/claude",
        ])
    }
}

struct InitializeTests {
    @Test func initializeResponseListsTheCLIsModels() throws {
        let info = try FixtureReplayTests.events("probe_control_misc").compactMap { event -> SessionInfo? in
            if case .initialized(let info) = event { return info }
            return nil
        }.first
        let models = try #require(info).models
        #expect(models.first?.value == "default")
        #expect(models.contains { $0.value == "opus" && $0.displayName == "Opus" })
        #expect(info?.permissionMode == "default")
    }
}

struct EffortLevelTests {
    @Test func modelsListTheirEffortLevelsFromTheRealInitialize() throws {
        let info = try FixtureReplayTests.events("probe_control_misc").compactMap { event -> SessionInfo? in
            if case .initialized(let info) = event { return info }
            return nil
        }.first
        let opus = try #require(info?.models.first { $0.value == "opus" })
        #expect(opus.supportedEffortLevels == ["low", "medium", "high", "xhigh", "max"])
    }
}

/// Stopping while a permission prompt is up: the CLI withdraws the request
/// it sent, by its id, as well as failing the tool.
struct PermissionCancelTests {
    @Test func stopWithdrawsThePendingRequestByID() throws {
        let events = try FixtureReplayTests.events("real_stop_pending_permission")
        let asked = events.compactMap { if case .permissionRequest(let request) = $0 { request.requestID } else { nil } }
        let withdrawn = events.compactMap { if case .permissionCancelled(let id) = $0 { id } else { nil } }
        #expect(asked.count == 1)
        #expect(withdrawn == asked)
        var queue = PermissionQueue()
        for event in events {
            switch event {
            case .permissionRequest(let request): queue.enqueue(request)
            case .permissionCancelled(let id): _ = queue.resolve(id)
            default: break
            }
        }
        #expect(queue.current == nil)
    }
}

/// A tool waiting on the user's answer isn't running yet, and its row says
/// so, replayed from the real permission captures.
struct AwaitingPermissionTests {
    func toolRow(_ transcript: Transcript) -> TranscriptEntry? {
        transcript.entries.first { if case .tool = $0.kind { true } else { false } }
    }

    @Test(arguments: ["real_permission_allow", "real_permission_deny"])
    func theRowWaitsUntilAnswered(fixture: String) throws {
        var transcript = Transcript()
        transcript.appendUser("prompt")
        var request: PermissionRequest?
        for event in try FixtureReplayTests.events(fixture) {
            transcript.apply(event)
            if case .permissionRequest(let asked) = event {
                request = asked
                let row = try #require(toolRow(transcript))
                #expect({ if case .tool(_, .awaitingPermission) = row.kind { true } else { false } }())
                #expect(RowWording.spokenTitle(of: row) == "Tool, waiting for permission")
                #expect(RowWording.visibleTitle(of: row) == "Waiting for you")
                #expect(RowWording.runningSeconds(of: row, at: Date()) == nil)
                let answeredAt = Date()
                transcript.permissionAnswered(toolUseID: asked.toolUseID, at: answeredAt)
                let answered = try #require(toolRow(transcript))
                #expect({ if case .tool(_, .running) = answered.kind { true } else { false } }())
                #expect(answered.startedAt == answeredAt)
            }
        }
        #expect(request != nil)
        let settled = try #require(toolRow(transcript))
        #expect({ if case .tool(_, .running) = settled.kind { false } else if case .tool(_, .awaitingPermission) = settled.kind { false } else { true } }())
    }

    @Test func aQuestionWaitsForAnAnswer() {
        let row = TranscriptEntry(id: "tool:q", kind: .tool(name: AskUserQuestion.toolName, status: .awaitingPermission), text: "")
        #expect(RowWording.spokenTitle(of: row) == "Tool, waiting for your answer")
    }
}

struct UnansweredPermissionTests {
    func toolKind(_ transcript: Transcript) -> TranscriptEntry.Kind? {
        transcript.entries.first { if case .tool = $0.kind { true } else { false } }?.kind
    }

    /// Real capture: Stop while a Write prompt is up. The CLI withdraws the
    /// prompt; the row stops waiting and ends failed.
    @Test func aWithdrawnPromptStopsTheRowWaiting() throws {
        var transcript = Transcript()
        transcript.appendUser("prompt")
        for event in try FixtureReplayTests.events("real_stop_pending_permission") {
            transcript.apply(event)
            if case .permissionCancelled = event {
                #expect(toolKind(transcript) != .tool(name: "Write", status: .awaitingPermission))
            }
        }
        #expect(toolKind(transcript) == .tool(name: "Write", status: .failed))
    }

    /// A turn that ends while a prompt is still up, with no result for the
    /// tool, doesn't leave its row waiting on a prompt that's gone.
    @Test func aTurnEndingUnansweredSettlesTheRow() throws {
        var transcript = Transcript()
        transcript.appendUser("prompt")
        var request: PermissionRequest?
        for event in try FixtureReplayTests.events("real_permission_allow") {
            if case .toolResult = event { break }
            transcript.apply(event)
            if case .permissionRequest(let asked) = event { request = asked; break }
        }
        #expect(request != nil)
        #expect({ if case .tool(_, .awaitingPermission)? = toolKind(transcript) { true } else { false } }())
        transcript.apply(.turnFinished(isError: true, summary: "API error"))
        #expect({ if case .tool(_, .failed)? = toolKind(transcript) { true } else { false } }())
    }

    /// The model button names the model, as the Claude app's does, from
    /// the CLI's real model lists: one capture's default was Opus 5.5
    /// (said as "Use the default model (currently Opus 5.5)"), another's
    /// Fable 5.1 (said as just "Fable 5.1").
    @Test(arguments: [("ask_user_question", "Opus 5.5"), ("real_ask_user_question", "Fable 5.1")])
    func modelsHaveShortNames(fixture: String, defaultName: String) throws {
        let models = try #require(try FixtureReplayTests.events(fixture).compactMap { event -> [ModelOption]? in
            if case .initialized(let info) = event { info.models } else { nil }
        }.first)
        let names = Dictionary(uniqueKeysWithValues: models.map { ($0.value, $0.shortName(among: models)) })
        #expect(names["default"] == defaultName)
        #expect(names["sonnet"] == "Sonnet 5.5")
        let bare = ModelOption(value: "x", displayName: "Custom", description: nil, supportedEffortLevels: [])
        #expect(bare.shortName(among: [bare]) == "Custom")
    }

    /// A fork resumes with --fork-session, so the CLI writes a new session
    /// and leaves the original alone; a plain resume doesn't pass it.
    @Test func forkingResumesWithForkSession() {
        let forked = ClaudeCLI.launchArguments(permissionMode: "default", model: nil, effort: nil, resumeSessionID: "abc", fork: true)
        #expect(forked.suffix(3) == ["--resume", "abc", "--fork-session"])
        let resumed = ClaudeCLI.launchArguments(permissionMode: "default", model: nil, effort: nil, resumeSessionID: "abc")
        #expect(!resumed.contains("--fork-session"))
        let fresh = ClaudeCLI.launchArguments(permissionMode: "default", model: nil, effort: nil, resumeSessionID: nil, fork: true)
        #expect(!fresh.contains("--fork-session"))
    }

    /// Every conversation can switch to Bypass permissions mid-way: the
    /// real CLI (2.1.310) refused set_permission_mode "bypassPermissions"
    /// with bypass_not_launched unless started with this flag.
    @Test func bypassPermissionsCanBeChosenMidConversation() {
        let arguments = ClaudeCLI.launchArguments(permissionMode: "default", model: nil, effort: nil, resumeSessionID: nil)
        #expect(arguments.contains("--allow-dangerously-skip-permissions"))
        // Allowing it isn't choosing it: the mode is still the one asked for.
        #expect(arguments.contains("--permission-mode=default"))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
    }

    /// A fork is titled apart from its original, once.
    @Test func forksAreTitledApart() {
        #expect(SessionHistory.forkTitle("Esc test A") == "Esc test A (fork)")
        #expect(SessionHistory.forkTitle("Esc test A (fork)") == "Esc test A (fork)")
    }
}

/// A session's result lists every model it used with its context window: a
/// 200K Opus 4.6 conversation with a 1M Haiku subagent reported both, and
/// the largest was taken, so 39,658 tokens read as 4% used, not 20%.
struct ContextWindowModelTests {
    @Test func contextIsMeasuredAgainstTheMainModelsWindow() throws {
        var tracker = MainModelTracker()
        var usage: ContextUsage?
        for line in try FixtureReplayTests.lines("real_two_models") where line.dir == "stdout" {
            let value = try JSONValue.parse(line.msg.line())
            tracker.observe(value)
            for case .contextUsage(let context) in try StreamEvent.readAll(value) {
                usage = context.measured(against: tracker.model)
            }
        }
        let context = try #require(usage)
        #expect(tracker.model == "claude-opus-4-6")
        #expect(context.usedTokens == 39_658)
        #expect(context.windowTokens == 200_000)
    }
}
