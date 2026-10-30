import Testing
@testable import ClaudeNative

/// What a keyboard shortcut asks a pop-up button to open.
@MainActor
struct MenuOpenerTests {
    /// Shift-Command-E asks for the model menu's Effort alone; Shift-
    /// Command-I, opening the same menu afterwards, gets all of it.
    @Test func aHeadingAsksForOneGroupUntilTheNextOpen() {
        let opener = MenuOpener()
        opener.open(heading: ModelMenu.effortHeading)
        #expect(opener.heading == "Effort")
        #expect(opener.requests == 1)
        opener.open()
        #expect(opener.heading == nil)
        #expect(opener.requests == 2)
    }
}
