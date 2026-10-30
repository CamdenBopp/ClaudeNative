import Foundation

/// A rule the CLI offers with a permission request ("always allow this"),
/// sent back as `updatedPermissions` when the user picks it. The CLI then
/// keeps the rule itself, in its own settings, so no allowlist lives here.
public struct PermissionSuggestion: Sendable, Equatable, Identifiable {
    /// Exactly what the CLI sent, returned unchanged.
    public let raw: JSONValue
    /// A button title that says what the rule allows and where it lasts.
    public let title: String
    /// The title split for a sheet too narrow to show it on one line: what
    /// the rule allows ("mkdir -p build and touch build/marker.txt"), and a
    /// short button title without it ("Always Allow in This Project on
    /// This Mac"). Nil when the title names nothing to split off.
    public let subject: String?
    public let action: String
    /// The rule itself, not its title: two folders named "src" in
    /// different places gave two rules one title, and so one id.
    public let id: String

    public init?(_ raw: JSONValue) {
        guard let parts = Self.describe(raw) else { return nil }
        self.raw = raw
        self.title = parts.title
        self.subject = parts.subject
        self.action = parts.action
        self.id = Self.identity(of: raw, title: parts.title)
    }

    init(raw: JSONValue, title: String) {
        self.raw = raw
        self.title = title
        self.subject = nil
        self.action = title
        self.id = Self.identity(of: raw, title: title)
    }

    /// The rule as one line of sorted-key JSON.
    private static func identity(of raw: JSONValue, title: String) -> String {
        (try? raw.line()).map { String(decoding: $0, as: UTF8.self) } ?? title
    }

    /// The plan card's "Accept and Allow Edits", as the Claude app offers
    /// it: accepts the plan and lets Claude edit files for the session.
    public static let acceptPlanAndAllowEdits = PermissionSuggestion(
        raw: .object(["type": .string("setMode"), "mode": .string("acceptEdits"), "destination": .string("session")]),
        title: "Accept and Allow Edits"
    )

    static func describe(_ suggestion: JSONValue) -> (title: String, subject: String?, action: String)? {
        func whole(_ title: String) -> (String, String?, String) { (title, nil, title) }
        switch suggestion["type"]?.string {
        case "setMode":
            guard let mode = suggestion["mode"]?.string else { return nil }
            switch mode {
            case "acceptEdits": return whole("Allow Edits for This Session")
            case "plan": return whole("Switch to Plan Only")
            default: return whole("Switch to \(mode) for This Session")
            }
        case "addRules":
            guard suggestion["behavior"]?.string == "allow",
                  let rules = suggestion["rules"]?.array, !rules.isEmpty
            else { return nil }
            let names = rules.compactMap { rule -> String? in
                guard let tool = rule["toolName"]?.string else { return nil }
                return rule["ruleContent"]?.string ?? "every \(tool) call"
            }
            guard !names.isEmpty else { return nil }
            return split(verb: "Always Allow", subject: joined(names), place: place(suggestion["destination"]?.string))
        case "addDirectories":
            guard let directories = suggestion["directories"]?.array?.compactMap(\.string), !directories.isEmpty else { return nil }
            let shown = directories.map { URL(fileURLWithPath: $0).lastPathComponent }
            return split(verb: "Allow Access to", subject: joined(shown), place: place(suggestion["destination"]?.string))
        default:
            return nil
        }
    }

    /// "Always Allow mkdir -p build in This Project on This Mac", and its
    /// halves. "Allow Access to" drops its "to" once the subject goes.
    private static func split(verb: String, subject: String, place: String) -> (title: String, subject: String?, action: String) {
        let shortVerb = verb.hasSuffix(" to") ? String(verb.dropLast(3)) : verb
        return ("\(verb) \(subject) \(place)", subject, "\(shortVerb) \(place)")
    }

    /// Where the CLI keeps the rule, in words.
    static func place(_ destination: String?) -> String {
        switch destination {
        case "session": "for This Session"
        case "localSettings": "in This Project on This Mac"
        case "projectSettings": "in This Project for Everyone"
        case "userSettings": "in Every Project"
        default: "from Now On"
        }
    }

    static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
        }
    }
}

extension PermissionRequest {
    /// The rules the CLI offered with this request that the app can show.
    public var suggestions: [PermissionSuggestion] {
        let sent = (rawSuggestions?.array ?? []).compactMap(PermissionSuggestion.init)
        // A plan comes with none; the Claude app's card offers this one.
        return isPlanApproval && sent.isEmpty ? [.acceptPlanAndAllowEdits] : sent
    }

    /// Claude asking to leave Plan mode with a plan to approve.
    public var isPlanApproval: Bool { toolName == PermissionWording.planToolName }
}
