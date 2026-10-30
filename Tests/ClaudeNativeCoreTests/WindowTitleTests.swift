import Testing
@testable import ClaudeNativeCore

/// Each window is named by its conversation, so two windows on the same
/// folder can be told apart in the Window menu and VoiceOver's window list.
struct WindowTitleTests {
    @Test func aWindowIsNamedByItsConversation() {
        #expect(WindowTitle.forConversation(nil) == "New Session")
        #expect(WindowTitle.forConversation("Write about rivers") == "Write about rivers")
        #expect(WindowTitle.forConversation("  ") == "New Session")
    }
}
