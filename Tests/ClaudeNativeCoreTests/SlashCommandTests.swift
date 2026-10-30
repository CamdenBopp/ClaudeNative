import Foundation
import Testing
@testable import ClaudeNativeCore

/// The message field's slash command picker, from the commands a real CLI
/// listed in its initialize response.
struct SlashCommandTests {
    static func capturedCommands() throws -> [SlashCommand] {
        let info = try #require(try FixtureReplayTests.events("permission_allow").lazy.compactMap { event -> SessionInfo? in
            if case .initialized(let info) = event { return info }
            return nil
        }.first)
        return info.commands
    }

    @Test func theCLIsCommandsAreReadWithTheirDescriptions() throws {
        let commands = try Self.capturedCommands()
        // 36 listed, less the one "__" plumbing command. The capture keeps
        // the CLI's own commands and four public skills.
        #expect(commands.count == 35)
        #expect(!commands.contains { $0.name.hasPrefix("__") })
        let compact = try #require(commands.first { $0.name == "compact" })
        #expect(compact.description == "Free up context by summarizing the conversation so far")
        #expect(compact.takesArgument)
        let clear = try #require(commands.first { $0.name == "clear" })
        #expect(clear.aliases == ["reset", "new"])
        // A user skill is offered too.
        #expect(commands.contains { $0.name == "unslop" })
    }

    @Test func onlyACommandStillBeingTypedIsAQuery() {
        #expect(SlashCommandSearch.query(in: "/") == "")
        #expect(SlashCommandSearch.query(in: "/com") == "com")
        #expect(SlashCommandSearch.query(in: "/model opus") == nil)
        #expect(SlashCommandSearch.query(in: "/compact\n") == nil)
        #expect(SlashCommandSearch.query(in: "Explain /etc") == nil)
        #expect(SlashCommandSearch.query(in: "") == nil)
    }

    @Test func namesThatStartWithTheQueryComeFirst() throws {
        let commands = try Self.capturedCommands()
        let found = SlashCommandSearch.matches("comp", in: commands).map(\.name)
        #expect(found.first == "compact")
        // An alias counts as a name: "reset" finds clear.
        #expect(SlashCommandSearch.matches("reset", in: commands).first?.name == "clear")
        // Then names containing it.
        let review = SlashCommandSearch.matches("review", in: commands).map(\.name)
        #expect(review == ["code-review", "security-review"])
        // Descriptions only when no name matches: "/co" lists the co-
        // commands, not every description with "correctness" in it.
        let co = SlashCommandSearch.matches("co", in: commands)
        #expect(co.allSatisfy { $0.name.contains("co") || $0.aliases.contains { $0.contains("co") } })
        #expect(SlashCommandSearch.matches("summarizing", in: commands).map(\.name) == ["compact"])
        #expect(SlashCommandSearch.matches("COMPACT", in: commands).first?.name == "compact")
        #expect(SlashCommandSearch.matches("", in: commands).count == commands.count)
        #expect(SlashCommandSearch.matches("zzzz", in: commands).isEmpty)
    }

    @Test func voiceOverHearsTheCommandAndAShortDescription() throws {
        let commands = try Self.capturedCommands()
        let compact = try #require(commands.first { $0.name == "compact" })
        #expect(SlashCommandSearch.spoken(compact) == "/compact, Free up context by summarizing the conversation so far")
        // A skill's paragraph-long description is cut to its first sentence.
        let skill = try #require(commands.first { $0.name == "c-bounds-safety" })
        let spoken = SlashCommandSearch.spoken(skill)
        #expect(spoken == "/c-bounds-safety, Guide for the C -fbounds-safety language extension")
        #expect(SlashCommandSearch.spoken(SlashCommand(name: "x", description: "")) == "/x")
        let long = SlashCommand(name: "long", description: String(repeating: "word ", count: 60))
        #expect(SlashCommandSearch.spoken(long).count <= "/long, ".count + SlashCommandSearch.maxSpokenDescriptionLength + 1)
        #expect(SlashCommandSearch.spoken(long).hasSuffix("…"))
    }

    @Test func theCountIsSaidInWords() {
        #expect(SlashCommandSearch.countWording(0) == "No commands match.")
        #expect(SlashCommandSearch.countWording(1) == "1 command.")
        #expect(SlashCommandSearch.countWording(12) == "12 commands.")
    }

    /// A name listed twice (a project and a user command, say) is offered
    /// once, the first listing: the picker's rows are keyed by name.
    @Test func aNameListedTwiceIsOfferedOnce() throws {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"init_1","response":{"models":[],"commands":[{"name":"deploy","description":"Project deploy"},{"name":"deploy","description":"User deploy"},{"name":"cost","description":"Cost"}]}}}"#
        guard case .initialized(let info)? = try StreamEvent.read(JSONValue.parse(Data(line.utf8))) else {
            Issue.record("not read as an initialize response")
            return
        }
        #expect(info.commands.map(\.name) == ["deploy", "cost"])
        #expect(info.commands.first?.description == "Project deploy")
    }

    @Test func everyNameMatchesAnEmptyQuery() {
        let compact = SlashCommand(name: "compact", description: "Summarize")
        #expect(SlashCommandSearch.nameMatches(compact, query: ""))
        #expect(SlashCommandSearch.nameMatches(compact, query: "COMP"))
        #expect(!SlashCommandSearch.nameMatches(compact, query: "summ"))
    }
}

/// The app's own commands, answered without the CLI.
struct LocalSlashCommandTests {
    @Test func projectsIsOfferedWithTheCLIsCommands() {
        let cli = [SlashCommand(name: "compact", description: "Summarize")]
        #expect(SlashCommand.withLocal(cli).map(\.name) == ["compact", "projects"])
        #expect(SlashCommandSearch.matches("proj", in: SlashCommand.withLocal(cli)).first?.name == "projects")
    }

    /// The CLI's own command of that name, if it ever has one, wins.
    @Test func theCLIsCommandOfTheSameNameWins() {
        let cli = [SlashCommand(name: "projects", description: "The CLI's")]
        #expect(SlashCommand.withLocal(cli).map(\.description) == ["The CLI's"])
    }

    @Test func onlyTheBareCommandIsAnsweredLocally() {
        #expect(SlashCommand.localCommand(in: "/projects") == .projects)
        #expect(SlashCommand.localCommand(in: "  /projects \n") == .projects)
        #expect(SlashCommand.localCommand(in: "/projects please") == nil)
        #expect(SlashCommand.localCommand(in: "/project") == nil)
    }

    /// Add > Slash Commands starts a command in an empty field; with a
    /// message typed it leaves it alone (it replaced it with "/").
    @Test func startingACommandKeepsATypedMessage() {
        #expect(SlashCommandSearch.starting(in: "") == "/")
        #expect(SlashCommandSearch.starting(in: "  ") == "/")
        #expect(SlashCommandSearch.starting(in: "Please fix the tests") == nil)
    }
}

