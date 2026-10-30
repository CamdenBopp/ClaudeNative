import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// A reply that finishes out of sight is unread; a turn cut off by opening
/// another session isn't a reply, and its end must not mark the session
/// just opened, which the window's own isWorking watcher did: by the time
/// it ran, the model already showed the new session.
extension MessageQueueTests {
    @Test func aReplyFinishedOutOfSightIsUnread() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        let session = try fixture.savedSession()
        defer { WorkingConversations.shared.seen(session.id) }
        WorkingConversations.shared.seen(session.id)
        model.start(in: fixture.directory, resuming: session)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { fixture.received().count == 1 }
        try fixture.finish(1)
        try await waitFor { !model.isWorking }
        #expect(WorkingConversations.shared.unread.contains(session.id))
    }

    @Test func openingAnotherSessionMidTurnDoesNotMarkIt() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        let (first, second) = (try fixture.savedSession(), try fixture.savedSession())
        defer { [first, second].forEach { WorkingConversations.shared.seen($0.id) } }
        [first, second].forEach { WorkingConversations.shared.seen($0.id) }
        model.start(in: fixture.directory, resuming: first)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { model.isWorking && fixture.received().count == 1 }
        model.start(in: fixture.directory, resuming: second)
        try await waitFor { model.isReady }
        #expect(!WorkingConversations.shared.unread.contains(second.id))
        #expect(!WorkingConversations.shared.unread.contains(first.id))
    }
}
