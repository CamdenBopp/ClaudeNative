import Foundation
import Testing
@testable import ClaudeNative

/// A file opened in a new window from the side panel takes its unsaved
/// edits along, and the panel lets it go.
@MainActor
struct OpenInNewWindowTests {
    @Test func theWindowGetsThePanelsEdits() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "handoff-\(UUID().uuidString).txt")
        try "on disk\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let panel = SidePanel()
        panel.open(.file(file))
        let document = panel.document(for: file)
        document.edited("typed in the panel\n")
        let moved = try #require(panel.handOff(file))
        #expect(moved === document)
        #expect(moved.text == "typed in the panel\n")
        // The panel no longer holds it, or shows it.
        #expect(panel.current != .file(file))
        #expect(panel.document(for: file) !== document)
    }
}
