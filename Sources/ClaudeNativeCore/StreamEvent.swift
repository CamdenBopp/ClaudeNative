import Foundation

/// One line from the CLI's stdout, read into the cases the client acts on.
/// Anything else is kept as `.unrecognized` so it shows up as a diagnostic
/// instead of vanishing.
public enum StreamEvent: Sendable, Equatable {
    case sessionStarted(sessionID: String, model: String?)
    /// The CLI's answer to `initialize`: the models and mode it offers.
    case initialized(SessionInfo)
    /// A new assistant message began streaming.
    case messageStarted(messageID: String)
    case textDelta(messageID: String?, text: String)
    /// A thinking block began streaming at content `index` of the current
    /// message.
    case thinkingStarted(index: Int)
    /// More text for the thinking block at `index`. The CLI sends empty text
    /// (only a token estimate) unless it runs with
    /// `--thinking-display summarized`.
    case thinkingDelta(index: Int, text: String)
    /// The content block at `index` of the current message finished.
    case contentBlockFinished(index: Int)
    /// A finished assistant message, with every content block it carries.
    case assistantMessage(messageID: String, blocks: [ContentBlock])
    case toolResult(toolUseID: String, text: String, isError: Bool)
    case permissionRequest(PermissionRequest)
    /// The CLI withdrew a permission request it sent, as it does when the
    /// turn is stopped while the prompt is still up.
    case permissionCancelled(requestID: String)
    case turnFinished(isError: Bool, summary: String?)
    /// The turn ended because the user stopped it (an interrupt, or a denial
    /// that asked to stop), not because something failed.
    case turnStopped
    /// The claude process exited. Not a turn's end: the app says the
    /// process stopped once its events have run out.
    case processExited(status: Int32)
    /// The mode the CLI says it's in, at the start of each turn. Accepting
    /// a plan, or Claude entering Plan mode, changes it from the CLI's side.
    case permissionModeReported(String)
    /// The account's usage limits changed.
    case usageLimits(UsageLimits)
    /// How full the context window was at the end of a turn.
    case contextUsage(ContextUsage)
    /// What Claude is doing between replies, as the CLI reports it.
    case activity(Activity)
    case unrecognized(type: String, raw: JSONValue)
}

/// A step the CLI reports while Claude works, outside the reply itself.
public enum Activity: Sendable, Equatable {
    /// `status: "compacting"`: the conversation is being summarized.
    case compacting
    /// The `status` line after compacting, carrying `compact_result`.
    case compacted(succeeded: Bool)
    /// `task_summary`: the CLI's own short line for the step in progress
    /// ("Running echo hi").
    case step(String)

    /// Reads a `system` line's activity, if it reports one. A `status` of
    /// "requesting", and a `task_summary` whose detail is null (the step
    /// ended), report none.
    static func read(_ line: JSONValue) -> Activity? {
        switch line["subtype"]?.string {
        case "status":
            if line["status"]?.string == "compacting" { return .compacting }
            guard let result = line["compact_result"]?.string else { return nil }
            return .compacted(succeeded: result == "success")
        case "task_summary":
            return line["detail"]?.string.map(Activity.step)
        default:
            return nil
        }
    }
}

public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    /// A thinking block's text: empty when the CLI withheld it or the block
    /// was redacted.
    case thinking(String)
}

public struct PermissionRequest: Sendable, Equatable, Identifiable {
    public let requestID: String
    public let toolName: String
    public let input: JSONValue
    public let toolUseID: String?
    /// The CLI's `permission_suggestions`, kept as sent.
    public let rawSuggestions: JSONValue?
    /// The agent asking, when it isn't the main conversation: a background
    /// agent asks whenever it gets there, during a later turn or between.
    public let agentID: String?
    public var id: String { requestID }

    public init(requestID: String, toolName: String, input: JSONValue, toolUseID: String? = nil, rawSuggestions: JSONValue? = nil, agentID: String? = nil) {
        self.requestID = requestID
        self.toolName = toolName
        self.input = input
        self.toolUseID = toolUseID
        self.rawSuggestions = rawSuggestions
        self.agentID = agentID
    }
}

public struct SessionInfo: Sendable, Equatable {
    public let models: [ModelOption]
    /// The slash commands this CLI accepts, for the message field's picker.
    public var commands: [SlashCommand] = []
    public let permissionMode: String?
    public let version: String?
}

public struct ModelOption: Sendable, Equatable, Identifiable, Hashable {
    /// What `set_model` takes ("default", "opus", a full model id).
    public let value: String
    public let displayName: String
    public let description: String?
    /// Effort levels the model accepts ("low" … "max"); empty when it has none.
    public let supportedEffortLevels: [String]
    /// The model the CLI would run for it ("claude-opus-5-5" for "default").
    public var resolvedModel: String? = nil
    public var id: String { value }

    /// The model's name as the Claude app's model button shows it, "Opus
    /// 5.5", rather than "Default (recommended)" or "Opus". Taken from the
    /// CLI's descriptions ("Opus 5.5 · Best for…", "Use the default model
    /// (currently Opus 5.5) · …"), or a sibling option that resolves to the
    /// same model; the display name when none says.
    public func shortName(among options: [ModelOption]) -> String {
        if let named = Self.leadingName(description) { return named }
        if let description, let open = description.range(of: "(currently "),
           let close = description[open.upperBound...].firstIndex(of: ")") {
            let named = description[open.upperBound..<close].trimmingCharacters(in: .whitespaces)
            if !named.isEmpty { return named }
        }
        if let resolvedModel, let sibling = options.first(where: { $0.value != value && $0.resolvedModel == resolvedModel }),
           let named = Self.leadingName(sibling.description) {
            return named
        }
        return displayName
    }

    /// "Opus 5.5" from "Opus 5.5 · Best for everyday tasks"; nil for a
    /// sentence such as "Use the default model…".
    private static func leadingName(_ description: String?) -> String? {
        guard let first = description?.components(separatedBy: " \u{00B7} ").first?.trimmingCharacters(in: .whitespaces),
              !first.isEmpty, first.count <= maxNameLength, first.last?.isNumber == true else { return nil }
        return first
    }

    /// Longer than any model's name, shorter than a sentence.
    static let maxNameLength = 24

    static func read(_ model: JSONValue) -> ModelOption? {
        guard let value = model["value"]?.string else { return nil }
        return ModelOption(
            value: value,
            displayName: model["displayName"]?.string ?? value,
            description: model["description"]?.string,
            supportedEffortLevels: model["supportedEffortLevels"]?.array?.compactMap(\.string) ?? [],
            resolvedModel: model["resolvedModel"]?.string
        )
    }
}

public enum StreamEventError: Error, Equatable {
    case notAnObject
    case missingField(type: String, field: String)
}

extension StreamEvent {
    /// Reads one decoded stdout line. Returns `nil` for lines that carry
    /// nothing the transcript needs (keep-alives, deltas of blocks we don't
    /// draw); throws when a line the client relies on is malformed.
    public static func read(_ line: JSONValue) throws -> StreamEvent? {
        guard let type = line["type"]?.string else { throw StreamEventError.notAnObject }
        // A subagent's own prompt and tool calls carry its Agent call's id;
        // they're that row's work. Shown, its Glob read as a tool the main
        // conversation ran, and a reopened session leaves them out anyway.
        if line["parent_tool_use_id"]?.string != nil, type == "assistant" || type == "user" { return nil }
        switch type {
        case "system":
            guard line["subtype"]?.string == "init" else { return Activity.read(line).map(StreamEvent.activity) }
            guard let sessionID = line["session_id"]?.string else {
                throw StreamEventError.missingField(type: type, field: "session_id")
            }
            return .sessionStarted(sessionID: sessionID, model: line["model"]?.string)

        case "stream_event":
            return try readStreamEvent(line)

        case "assistant":
            // An API error the CLI wrote as a reply ("<synthetic>" model).
            // The error result after it says the same, as a notice; as a
            // reply too, VoiceOver read it twice, once as Claude's words.
            if line["is_api_error_message"]?.bool == true { return nil }
            guard let message = line["message"], let messageID = message["id"]?.string else {
                throw StreamEventError.missingField(type: type, field: "message.id")
            }
            let blocks = (message["content"]?.array ?? []).compactMap(ContentBlock.read)
            return .assistantMessage(messageID: messageID, blocks: blocks)

        case "user":
            // Replayed user text is already in the transcript; only tool
            // results are new information here.
            return toolResults(in: line).first

        case "control_request":
            guard let requestID = line["request_id"]?.string, let request = line["request"] else {
                throw StreamEventError.missingField(type: type, field: "request_id")
            }
            guard request["subtype"]?.string == "can_use_tool" else {
                return .unrecognized(type: "control_request/\(request["subtype"]?.string ?? "?")", raw: line)
            }
            guard let toolName = request["tool_name"]?.string else {
                throw StreamEventError.missingField(type: type, field: "request.tool_name")
            }
            return .permissionRequest(PermissionRequest(
                requestID: requestID,
                toolName: toolName,
                input: request["input"] ?? .object([:]),
                toolUseID: request["tool_use_id"]?.string,
                rawSuggestions: request["permission_suggestions"],
                agentID: request["agent_id"]?.string
            ))

        case "result":
            if line["terminal_reason"]?.string?.hasPrefix("aborted") == true {
                return .turnStopped
            }
            return .turnFinished(
                isError: line["is_error"]?.bool ?? (line["subtype"]?.string != "success"),
                summary: line["result"]?.string
            )

        case "control_cancel_request":
            guard let requestID = line["request_id"]?.string else {
                throw StreamEventError.missingField(type: type, field: "request_id")
            }
            return .permissionCancelled(requestID: requestID)

        case "control_response":
            guard let response = line["response"]?["response"],
                  let models = response["models"]?.array
            else { return nil }
            return .initialized(SessionInfo(
                models: models.compactMap(ModelOption.read),
                commands: SlashCommand.list(response["commands"]),
                permissionMode: response["current_permission_mode"]?.string,
                version: response["claude_code_version"]?.string
            ))

        case "rate_limit_event":
            return UsageLimits.read(line).map(StreamEvent.usageLimits)

        case "keep_alive":
            return nil

        default:
            return .unrecognized(type: type, raw: line)
        }
    }

    private static func readStreamEvent(_ line: JSONValue) throws -> StreamEvent? {
        guard let event = line["event"], let eventType = event["type"]?.string else {
            throw StreamEventError.missingField(type: "stream_event", field: "event.type")
        }
        switch eventType {
        case "message_start":
            guard let messageID = event["message"]?["id"]?.string else {
                throw StreamEventError.missingField(type: "stream_event", field: "event.message.id")
            }
            return .messageStarted(messageID: messageID)
        case "content_block_start":
            let blockType = event["content_block"]?["type"]?.string
            guard blockType == "thinking" || blockType == "redacted_thinking" else { return nil }
            return .thinkingStarted(index: try blockIndex(of: event))
        case "content_block_delta":
            switch event["delta"]?["type"]?.string {
            case "text_delta":
                guard let text = event["delta"]?["text"]?.string else { return nil }
                return .textDelta(messageID: nil, text: text)
            case "thinking_delta":
                guard let text = event["delta"]?["thinking"]?.string else {
                    throw StreamEventError.missingField(type: "stream_event", field: "event.delta.thinking")
                }
                return .thinkingDelta(index: try blockIndex(of: event), text: text)
            default:
                return nil
            }
        case "content_block_stop":
            return .contentBlockFinished(index: try blockIndex(of: event))
        default:
            return nil
        }
    }

    private static func blockIndex(of event: JSONValue) throws -> Int {
        guard let index = event["index"]?.int else {
            throw StreamEventError.missingField(type: "stream_event", field: "event.index")
        }
        return index
    }

    static func text(of content: JSONValue?) -> String {
        TranscriptContent.text(of: content)
    }

    static func toolResults(in line: JSONValue) -> [StreamEvent] {
        (line["message"]?["content"]?.array ?? []).compactMap { result in
            guard result["type"]?.string == "tool_result", let id = result["tool_use_id"]?.string else { return nil }
            return .toolResult(toolUseID: id, text: text(of: result["content"]), isError: result["is_error"]?.bool ?? false)
        }
    }
}

extension StreamEvent {
    /// Every event one stdout line carries. A `result` line ends the turn
    /// and also reports context use, so it yields two.
    public static func readAll(_ line: JSONValue) throws -> [StreamEvent] {
        if line["type"]?.string == "user" {
            return line["parent_tool_use_id"]?.string == nil ? toolResults(in: line) : []
        }
        var events = try read(line).map { [$0] } ?? []
        if line["type"]?.string == "system", line["subtype"]?.string == "init",
           line["parent_tool_use_id"]?.string == nil, let mode = line["permissionMode"]?.string {
            events.append(.permissionModeReported(mode))
        }
        if line["type"]?.string == "result", let context = ContextUsage.read(line) {
            events.append(.contextUsage(context))
        }
        return events
    }
}

extension ContentBlock {
    static func read(_ block: JSONValue) -> ContentBlock? {
        switch block["type"]?.string {
        case "text":
            return block["text"]?.string.map(ContentBlock.text)
        case "tool_use":
            guard let id = block["id"]?.string, let name = block["name"]?.string else { return nil }
            return .toolUse(id: id, name: name, input: block["input"] ?? .object([:]))
        case "thinking":
            return .thinking(block["thinking"]?.string ?? "")
        case "redacted_thinking":
            return .thinking("")
        default:
            return nil
        }
    }
}
