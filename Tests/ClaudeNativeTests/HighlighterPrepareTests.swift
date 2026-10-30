import Testing
@testable import CodeHighlighting

/// The app compiles highlight queries off the main thread at launch. The
/// first code block opened compiled them on it: 0.7 s of a 0.9 s first
/// open of a conversation's latest page, most of it Swift's query.
struct HighlighterPrepareTests {
    @Test func prepareReadiesEveryLanguageAndItsInjections() {
        let injected = Set(CodeLanguage.allCases.flatMap { $0.injections.map(\.grammar) })
        let expected = CodeLanguage.allCases.count + injected.subtracting(CodeLanguage.allCases.map { .language($0) }).count
        #expect(CodeHighlighter.prepare() == expected)
    }
}
