import Foundation

/// A one-line, speakable description of a tool call.
public enum ToolSummary {
    public static func describe(name: String, input: JSONValue) -> String {
        let detail = ["file_path", "command", "pattern", "url", "description", "path"]
            .lazy
            .compactMap { input[$0]?.string }
            .first
        let shownName = spokenName(name)
        guard let detail else { return shownName }
        return "\(shownName): \(detail)"
    }

    /// Prefix the CLI puts on every MCP tool: `mcp__<server>__<tool>`.
    static let mcpPrefix = "mcp__"
    static let mcpSeparator = "__"

    /// A tool's name as words. MCP tools read tool first, then the server in
    /// parentheses ("navigate (chrome devtools)"), with underscores and
    /// hyphens as spaces; VoiceOver spells the raw name out piece by piece.
    /// Built-in names ("Bash", "Edit") and anything not shaped like an MCP
    /// name come back unchanged.
    public static func spokenName(_ name: String) -> String {
        guard name.hasPrefix(mcpPrefix) else { return name }
        let rest = name.dropFirst(mcpPrefix.count)
        guard let split = rest.range(of: mcpSeparator) else { return name }
        let server = words(rest[..<split.lowerBound])
        let tool = words(rest[split.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return name }
        return "\(tool) (\(server))"
    }

    private static func words(_ identifier: Substring) -> String {
        identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).joined(separator: " ")
    }

    /// Rewrites paths inside `base` as paths relative to it, so a row reads
    /// "Write: Sources/App.swift" rather than the whole absolute path.
    public static func shorten(_ text: String, relativeTo base: URL?) -> String {
        guard let base else { return text }
        var path = base.standardizedFileURL.path
        // macOS reports temp folders under both /tmp and /private/tmp; strip
        // the longer spelling first so it isn't left half-replaced.
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        return text
            .replacingOccurrences(of: "/private" + path + "/", with: "")
            .replacingOccurrences(of: path + "/", with: "")
    }
}
