import Foundation
import Testing
@testable import ClaudeNative

@MainActor
struct FileSearchSelectionTests {
    let root = URL(fileURLWithPath: "/tmp/file-search-qa")
    let alpha = URL(fileURLWithPath: "/tmp/file-search-qa/alpha.txt")
    let beta = URL(fileURLWithPath: "/tmp/file-search-qa/beta.txt")

    @Test func returnWaitsForTheCurrentQuery() {
        let old = FilesView.SearchKey(query: "alpha", folder: root)
        let current = FilesView.SearchKey(query: "beta", folder: root)
        #expect(FilesView.openingMatch(selection: alpha, matches: [alpha], matchedFor: old, current: current) == nil)
    }

    @Test func returnWaitsForTheCurrentFolder() {
        let old = FilesView.SearchKey(query: "alpha", folder: root)
        let current = FilesView.SearchKey(query: "alpha", folder: root.appending(path: "other"))
        #expect(FilesView.openingMatch(selection: alpha, matches: [alpha], matchedFor: old, current: current) == nil)
    }

    @Test func anOldSelectionCannotOverrideTheNewMatches() {
        let key = FilesView.SearchKey(query: "beta", folder: root)
        #expect(FilesView.openingMatch(selection: alpha, matches: [beta], matchedFor: key, current: key) == beta)
        #expect(FilesView.openingMatch(selection: alpha, matches: [], matchedFor: key, current: key) == nil)
    }

    @Test func aCurrentSelectionIsKept() {
        let key = FilesView.SearchKey(query: "txt", folder: root)
        #expect(FilesView.openingMatch(selection: beta, matches: [alpha, beta], matchedFor: key, current: key) == beta)
        #expect(FilesView.openingMatch(selection: nil, matches: [alpha, beta], matchedFor: key, current: key) == alpha)
    }
}
