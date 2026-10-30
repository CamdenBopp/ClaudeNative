import Foundation
import Testing
@testable import ClaudeNative

/// Quitting asks about edits not yet saved: it dropped them without a
/// word. The app finds them here, in the panel's documents and editor
/// windows alike.
@MainActor
@Suite(.serialized)
struct UnsavedDocumentsTests {
    @Test func unsavedDocumentsAreTheDirtyOnesStillOpen() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "unsaved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appending(path: "a.txt"), b = folder.appending(path: "b.txt")
        try "one\n".write(to: a, atomically: true, encoding: .utf8)
        try "two\n".write(to: b, atomically: true, encoding: .utf8)
        // Only this test's: other suites open documents too.
        func unsaved() -> [EditorDocument] { EditorDocument.unsaved.filter { $0.url.path.hasPrefix(folder.path) } }
        let clean = EditorDocument(url: a)
        // In its own pool: the registry hands back autoreleased references,
        // which would keep a dropped document alive until the pool drains.
        autoreleasepool {
            var dirty: EditorDocument? = EditorDocument(url: b)
            dirty?.edited("two, changed\n")
            #expect(unsaved().map(\.url) == [b])
            dirty?.save()
            #expect(unsaved().isEmpty)
            dirty?.edited("two, changed again\n")
            #expect(unsaved().count == 1)
            dirty = nil
        }
        // A document closed and gone has nothing left to ask about.
        #expect(unsaved().isEmpty)
        _ = clean
    }
}
