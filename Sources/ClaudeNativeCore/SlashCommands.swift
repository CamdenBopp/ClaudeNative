import Foundation

/// A slash command the CLI offers this session ("/compact"), as its
/// initialize response lists it: built-in commands, the user's skills and
/// plugin commands. The list comes from the CLI rather than being kept
/// here, so it always matches what this CLI accepts.
public struct SlashCommand: Sendable, Equatable, Identifiable, Hashable {
    public let name: String
    public let description: String
    /// What follows the command ("<model>", "[name]"); empty when the CLI
    /// lists none.
    public let argumentHint: String
    /// Other names the CLI accepts for it ("reset" for "clear").
    public let aliases: [String]
    public var id: String { name }

    /// What goes in the message field: "/compact".
    public var invocation: String { "/" + name }

    /// Whether choosing it leaves room to type what follows instead of
    /// sending it straight away.
    public var takesArgument: Bool { !argumentHint.isEmpty }

    public init(name: String, description: String, argumentHint: String = "", aliases: [String] = []) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.aliases = aliases
    }

    /// Commands the app answers itself rather than sending to the CLI.
    /// "/projects" lists the projects to start a conversation in.
    public static let projects = SlashCommand(name: "projects", description: "List your projects and start a session in one")
    public static let local: [SlashCommand] = [projects]

    /// The CLI's commands with the app's own added, unless the CLI already
    /// has one by that name (the CLI's wins).
    public static func withLocal(_ cli: [SlashCommand]) -> [SlashCommand] {
        let names = Set(cli.map(\.name))
        return cli + local.filter { !names.contains($0.name) }
    }

    /// The local command `draft` invokes, if it is just one ("/projects").
    public static func localCommand(in draft: String) -> SlashCommand? {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return local.first { $0.invocation == typed }
    }

    /// The commands in an initialize response, each name once: a name
    /// listed twice (a project and a user command) keeps its first listing,
    /// since the picker keys its rows by name.
    static func list(_ value: JSONValue?) -> [SlashCommand] {
        var seen = Set<String>()
        return (value?.array ?? []).compactMap(read).filter { seen.insert($0.name).inserted }
    }

    /// Commands named with a leading "__" are the CLI's own plumbing
    /// ("__remote-workflow") and aren't offered.
    static func read(_ value: JSONValue) -> SlashCommand? {
        guard let name = value["name"]?.string, !name.isEmpty, !name.hasPrefix("__") else { return nil }
        return SlashCommand(
            name: name,
            description: value["description"]?.string ?? "",
            argumentHint: value["argumentHint"]?.string ?? "",
            aliases: value["aliases"]?.array?.compactMap(\.string) ?? []
        )
    }
}

/// Finding and speaking slash commands while one is typed in the message
/// field. As in Clarc's picker, the keyboard stays in the field: the arrow
/// keys move a highlight and VoiceOver hears each highlighted command.
public enum SlashCommandSearch {
    /// The field after Add > Slash Commands: "/" when nothing's typed, or
    /// nil to leave a typed message alone. A command is the whole message,
    /// so there's nowhere to put one after it.
    public static func starting(in draft: String) -> String? {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : nil
    }

    /// Said when a typed message keeps Slash Commands from starting one.
    public static let keptMessageNotice = "Slash commands start an empty message. Your message is still here."

    /// Longest description VoiceOver hears for a highlighted command. Skill
    /// descriptions run to paragraphs; one is heard per arrow press.
    static let maxSpokenDescriptionLength = 140
    /// How long typing must pause before the count is said. Longer than
    /// the conversation search's: half a second in, VoiceOver was still
    /// echoing the typed command and the count went unheard (live).
    public static let announcementDelay: Duration = .milliseconds(1_500)

    /// The text after "/" while the draft is a command still being typed:
    /// it starts with "/" and has no space or line break yet. Nil otherwise.
    public static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        guard !rest.contains(where: \.isWhitespace) else { return nil }
        return String(rest)
    }

    /// The commands for `query`: names (or aliases) that start with it,
    /// then names that contain it, each group in name order. Only when no
    /// name matches are descriptions searched: "/co" said "53 commands" with
    /// every "correctness" and "code" in them (heard live). Case doesn't
    /// matter. An empty query lists all.
    public static func matches(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] {
        let needle = query.lowercased()
        let byName = commands.sorted { $0.name < $1.name }
        guard !needle.isEmpty else { return byName }
        func names(_ command: SlashCommand) -> [String] { ([command.name] + command.aliases).map { $0.lowercased() } }
        let starts = byName.filter { names($0).contains { $0.hasPrefix(needle) } }
        let contains = byName.filter { command in
            !starts.contains(command) && names(command).contains { $0.contains(needle) }
        }
        guard starts.isEmpty, contains.isEmpty else { return starts + contains }
        return byName.filter { $0.description.lowercased().contains(needle) }
    }

    /// Whether `command`'s name or an alias contains `query`, as opposed
    /// to a match found only in its description.
    public static func nameMatches(_ command: SlashCommand, query: String) -> Bool {
        // An empty query ("/" alone) matches every name. String.contains("")
        // is false, which made Return send a bare "/".
        let needle = query.lowercased()
        guard !needle.isEmpty else { return true }
        return ([command.name] + command.aliases).contains { $0.lowercased().contains(needle) }
    }

    /// What VoiceOver hears for a highlighted command: "/compact, Free up
    /// context by summarizing the conversation so far". A long description
    /// is cut at its first sentence, then at a word.
    public static func spoken(_ command: SlashCommand) -> String {
        let description = shortened(command.description)
        return description.isEmpty ? command.invocation : "\(command.invocation), \(description)"
    }

    /// How many commands match, said when the list first appears.
    public static func countWording(_ count: Int) -> String {
        switch count {
        case 0: "No commands match."
        case 1: "1 command."
        default: "\(count) commands."
        }
    }

    static func shortened(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        var sentence = flat
        if let end = flat.range(of: ". ") { sentence = String(flat[..<end.lowerBound]) }
        guard sentence.count > maxSpokenDescriptionLength else { return sentence }
        let cut = sentence.prefix(maxSpokenDescriptionLength)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }
}
