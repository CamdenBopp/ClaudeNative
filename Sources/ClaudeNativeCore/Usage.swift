import Foundation

/// How much of the account's usage limits is spent, from the CLI's
/// `rate_limit_event` lines.
public struct UsageLimits: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        /// 0 to 1.
        public let utilization: Double
        public let resetsAt: Date
    }

    public let fiveHour: Window?
    public let weekly: Window?

    static func read(_ line: JSONValue) -> UsageLimits? {
        guard let windows = line["rate_limit_info"]?["unifiedWindows"] else { return nil }
        let limits = UsageLimits(fiveHour: window(windows["five_hour"]), weekly: window(windows["seven_day"]))
        return limits.fiveHour == nil && limits.weekly == nil ? nil : limits
    }

    private static func window(_ value: JSONValue?) -> Window? {
        guard case .number(let utilization)? = value?["utilization"],
              case .number(let resets)? = value?["resetsAt"]
        else { return nil }
        return Window(utilization: utilization, resetsAt: Date(timeIntervalSince1970: resets))
    }
}

/// How full the model's context window is after the last API call of a turn.
public struct ContextUsage: Sendable, Equatable {
    public let usedTokens: Int
    public let windowTokens: Int
    /// Each model's context window, as the result reports them.
    let windowsByModel: [String: Int]

    public init(usedTokens: Int, windowTokens: Int) {
        self.init(usedTokens: usedTokens, windowTokens: windowTokens, windowsByModel: [:])
    }

    init(usedTokens: Int, windowTokens: Int, windowsByModel: [String: Int]) {
        self.usedTokens = usedTokens
        self.windowTokens = windowTokens
        self.windowsByModel = windowsByModel
    }

    /// Measured against `model`'s window when the result reports it.
    func measured(against model: String?) -> ContextUsage {
        guard let model, let window = windowsByModel[model] else { return self }
        return ContextUsage(usedTokens: usedTokens, windowTokens: window, windowsByModel: windowsByModel)
    }

    public var fraction: Double { windowTokens > 0 ? Double(usedTokens) / Double(windowTokens) : 0 }

    /// From a `result` line: the last iteration's input, cache-read and
    /// cache-write tokens are what the model saw, measured against the
    /// context window the result reports for that model.
    static func read(_ result: JSONValue) -> ContextUsage? {
        guard let last = result["usage"]?["iterations"]?.array?.last else { return nil }
        let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .compactMap { last[$0]?.int }
            .reduce(0, +)
        let windows = (result["modelUsage"]?.object ?? [:]).compactMapValues { $0["contextWindow"]?.int }
        guard used > 0, let window = windows.values.max() else { return nil }
        return ContextUsage(usedTokens: used, windowTokens: window, windowsByModel: windows)
    }
}

/// The status line under the prompt, worded to be read aloud in one pass.
public enum UsageWording {
    public static func sentence(limits: UsageLimits?, context: ContextUsage?, now: Date = Date()) -> String? {
        var parts: [String] = []
        if let window = limits?.fiveHour {
            parts.append("5-hour limit \(percent(window.utilization)) used, resets \(relative(window.resetsAt, now: now))")
        }
        if let window = limits?.weekly {
            parts.append("weekly limit \(percent(window.utilization)) used, resets \(relative(window.resetsAt, now: now))")
        }
        if let context {
            parts.append("context \(percent(context.fraction)) full")
        }
        guard !parts.isEmpty else { return nil }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ". ") + "."
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// "in 3 hours 26 minutes", "in 6 days"; the largest two units.
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        guard seconds >= 60 else { return "in under a minute" }
        let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s")" }
        let units = [(days, "day"), (hours, "hour"), (minutes, "minute")].filter { $0.0 > 0 }.prefix(2)
        return "in " + units.map { unit($0.0, $0.1) }.joined(separator: " ")
    }
}

/// The model the main conversation runs, from its own assistant lines;
/// a subagent's carry its Agent call's id and are passed over.
public struct MainModelTracker: Sendable {
    public private(set) var model: String?

    public init() {}

    public mutating func observe(_ line: JSONValue) {
        guard line["type"]?.string == "assistant", line["parent_tool_use_id"]?.string == nil,
              let model = line["message"]?["model"]?.string, model != "<synthetic>" else { return }
        self.model = model
    }
}
