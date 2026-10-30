import Testing
@testable import ClaudeNativeCore

/// The permission sheet lists suggestions by id. Two folders with the same
/// name ("src" in two places) gave two rules one id, so SwiftUI could show
/// or press the wrong one.
struct PermissionSuggestionIDTests {
    @Test func rulesForSameNamedFoldersHaveTheirOwnIDs() throws {
        func rule(_ path: String) throws -> PermissionSuggestion {
            try #require(PermissionSuggestion(.object([
                "type": .string("addDirectories"), "directories": .array([.string(path)]), "destination": .string("session"),
            ])))
        }
        let (a, b) = (try rule("/Users/me/one/src"), try rule("/Users/me/two/src"))
        #expect(a.title == b.title)
        #expect(a.id != b.id)
    }
}
