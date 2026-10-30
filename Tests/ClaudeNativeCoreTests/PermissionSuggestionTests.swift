import Testing
@testable import ClaudeNativeCore

/// Against real_always_allow.jsonl: a real Bash request whose suggestion was
/// sent back, after which the CLI wrote both rules to settings.local.json.
struct PermissionSuggestionTests {
    func capturedRequest(_ fixture: String) throws -> PermissionRequest {
        let request = try FixtureReplayTests.events(fixture).compactMap { event -> PermissionRequest? in
            if case .permissionRequest(let request) = event { return request }
            return nil
        }.first
        return try #require(request)
    }

    @Test func bashRulesReadAsOneButton() throws {
        let suggestions = try capturedRequest("real_always_allow").suggestions
        #expect(suggestions.map(\.title) == ["Always Allow mkdir -p build and touch build/marker.txt in This Project on This Mac"])
    }

    /// A sheet too narrow for the whole title shows what the rule allows
    /// beside a short button, and the halves still say all of it.
    @Test func bashRulesSplitIntoWhatAndWhere() throws {
        let suggestion = try #require(try capturedRequest("real_always_allow").suggestions.first)
        #expect(suggestion.subject == "mkdir -p build and touch build/marker.txt")
        #expect(suggestion.action == "Always Allow in This Project on This Mac")
    }

    @Test func directoriesSplitWithoutTheDanglingTo() throws {
        let raw: JSONValue = .object(["type": .string("addDirectories"), "directories": .array([.string("/tmp/out")]), "destination": .string("session")])
        let suggestion = try #require(PermissionSuggestion(raw))
        #expect(suggestion.title == "Allow Access to out for This Session")
        #expect(suggestion.subject == "out")
        #expect(suggestion.action == "Allow Access for This Session")
    }

    @Test func aModeHasNothingToSplit() throws {
        let suggestion = try #require(try capturedRequest("real_permission_allow").suggestions.first)
        #expect(suggestion.subject == nil)
        #expect(suggestion.action == suggestion.title)
    }

    @Test func editModeReadsAsAllowEdits() throws {
        #expect(try capturedRequest("real_permission_allow").suggestions.map(\.title) == ["Allow Edits for This Session"])
    }

    @Test func rememberingSendsTheSuggestionTheCLIAccepted() throws {
        let request = try capturedRequest("real_always_allow")
        let accepted = try #require(FixtureReplayTests.lines("real_always_allow").first {
            $0.dir == "stdin" && $0.msg["type"]?.string == "control_response"
        }).msg["response"]?["response"]?["updatedPermissions"]
        let ours = ClaudeCLI.permissionResponse(to: request, allow: true, remember: request.suggestions.first)
        #expect(ours["response"]?["response"]?["updatedPermissions"] == accepted)
    }

    @Test func aDenyNeverRemembers() throws {
        let request = try capturedRequest("real_always_allow")
        let ours = ClaudeCLI.permissionResponse(to: request, allow: false, remember: request.suggestions.first)
        #expect(ours["response"]?["response"]?["updatedPermissions"] == nil)
    }

    @Test func unknownSuggestionsAreLeftOut() {
        #expect(PermissionSuggestion(.object(["type": .string("removeRules")])) == nil)
        #expect(PermissionSuggestion(.object(["type": .string("addRules"), "behavior": .string("deny"), "rules": .array([])])) == nil)
    }
}
