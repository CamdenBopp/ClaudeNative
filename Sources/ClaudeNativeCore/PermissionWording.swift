import Foundation

/// What a permission prompt says about the request, beyond its title.
public enum PermissionWording {
    /// The tool Claude calls to present a plan for approval.
    public static let planToolName = "ExitPlanMode"

    /// One sentence saying what Claude is asking to do, in plain words.
    public static func explanation(toolName: String) -> String {
        switch toolName {
        case "Bash": "Claude wants to run a command."
        case "Write": "Claude wants to create or replace a file."
        case "Edit", "MultiEdit": "Claude wants to change a file."
        case "NotebookEdit": "Claude wants to change a notebook."
        case "Read": "Claude wants to read a file."
        case "WebFetch": "Claude wants to fetch a web page."
        case "WebSearch": "Claude wants to search the web."
        case AskUserQuestion.toolName: "Claude has a question for you."
        default: "Claude wants to use \(ToolSummary.spokenName(toolName))."
        }
    }

    /// The request's detail without the tool name in front: the command,
    /// path or address itself. Nil when the tool gave none.
    public static func detail(toolName: String, input: JSONValue) -> String? {
        // The plan itself, which the summary leaves out.
        if toolName == planToolName { return input["plan"]?.string }
        let described = ToolSummary.describe(name: toolName, input: input)
        let prefix = "\(ToolSummary.spokenName(toolName)): "
        guard described.hasPrefix(prefix) else { return nil }
        return String(described.dropFirst(prefix.count))
    }

    /// The prompt's question, as the Claude app asks it: "Allow Claude to
    /// run git status?", "Allow Claude to edit App.swift?". A file is named
    /// by its name, a page by its host; a long command is cut short, since
    /// the prompt shows it whole below.
    public static func question(toolName: String, input: JSONValue) -> String {
        if toolName == planToolName { return "Claude proposed a plan" }
        let action: String? = switch toolName {
        case "Bash": input["command"]?.string.map { "run \(shortened(firstLine($0)))" }
        case "Edit", "MultiEdit", "NotebookEdit": fileName(input).map { "edit \($0)" }
        case "Write": fileName(input).map { "write \($0)" }
        case "Read": fileName(input).map { "read \($0)" }
        case "WebFetch": input["url"]?.string.map { "fetch \(URL(string: $0)?.host() ?? shortened($0))" }
        case "WebSearch": input["query"]?.string.map { "search the web for \u{201C}\(shortened($0))\u{201D}" }
        default: nil
        }
        return "Allow Claude to \(action ?? "use \(ToolSummary.spokenName(toolName))")?"
    }

    /// Whether the question already says what the tool does, so the
    /// explanation under it would repeat it.
    public static func questionSaysTheAction(toolName: String, input: JSONValue) -> Bool {
        !question(toolName: toolName, input: input).hasPrefix("Allow Claude to use ")
    }

    /// What Claude reads when a plan is sent back to revise: the user's
    /// note, or a plain request when they left it empty.
    public static func revisionMessage(_ note: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "The user wants the plan revised before you start. Ask them what should change."
            : "The user wants the plan revised before you start. What should change: \(trimmed)"
    }

    /// The buttons that answer no and yes: a plan is rejected or accepted,
    /// as the Claude app's plan card says.
    public static func answerTitles(toolName: String) -> (deny: String, allow: String) {
        toolName == planToolName ? ("Reject", "Accept") : ("Deny", "Allow Once")
    }

    /// The longest command or query the question quotes in full.
    static let questionTargetLimit = 60

    private static func fileName(_ input: JSONValue) -> String? {
        (input["file_path"]?.string ?? input["notebook_path"]?.string).map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line == text ? text : line + "\u{2026}"
    }

    private static func shortened(_ text: String) -> String {
        text.count <= questionTargetLimit ? text : String(text.prefix(questionTargetLimit)) + "\u{2026}"
    }
}
