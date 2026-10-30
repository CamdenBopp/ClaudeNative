import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Deleting a conversation stops every window showing it, not just the
/// one the delete came from: each open window's model is findable, and a
/// closed window's model is not.
@MainActor
struct AppModelRegistryTests {
    @Test func everyOpenWindowsModelIsFindableUntilItCloses() {
        let first = AppModel()
        let second = AppModel()
        #expect(AppModel.openModels.contains { $0 === first })
        #expect(AppModel.openModels.contains { $0 === second })
        second.close()
        #expect(!AppModel.openModels.contains { $0 === second })
        #expect(AppModel.openModels.contains { $0 === first })
        // Neither shows a conversation.
        #expect(AppModel.models(showing: "any").isEmpty)
        first.close()
    }

    /// A second Delete of a conversation already being deleted does
    /// nothing, rather than skipping the wait for its CLI.
    @Test func aConversationIsReleasedOnceAtATime() async {
        let window = AppModel()
        defer { window.close() }
        let id = "release-\(UInt64.random(in: 0...UInt64.max))"
        #expect(await AppModel.release(id, from: window, startNewHere: {}))
        #expect(await !AppModel.release(id, from: window, startNewHere: {}))
        AppModel.finishedDeleting(id)
        #expect(await AppModel.release(id, from: window, startNewHere: {}))
        AppModel.finishedDeleting(id)
    }

    /// While a conversation is being deleted, no window reopens it: its
    /// file is about to go to the Trash.
    @Test func aConversationBeingDeletedIsntReopened() async {
        let window = AppModel()
        defer { window.close() }
        let id = UUID().uuidString.lowercased()
        let session = SessionHistory.SessionSummary(
            id: id, title: "x", lastModified: .now, fileURL: URL(fileURLWithPath: "/nonexistent/\(id).jsonl")
        )
        #expect(await AppModel.release(id, from: window, startNewHere: {}))
        window.start(in: FileManager.default.temporaryDirectory, resuming: session)
        #expect(window.sessionID == nil)
        AppModel.finishedDeleting(id)
    }
}
