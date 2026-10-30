import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// After Stop pauses the queue, a new message joins it and waits for
/// Resume. It only said "Message queued.", so nothing told the user it
/// wouldn't go.
extension MessageQueueTests {
    @Test func aMessageSentWhileTheQueueIsPausedSaysResumeSendsIt() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        var heard: [String] = []
        let listener = Announcer.listen { text, _ in if text.hasPrefix("Message queued") { heard.append(text) } }
        defer { Announcer.stopListening(listener) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { fixture.received().count == 1 }
        model.send("second")
        model.interrupt()
        try await waitFor { !model.isWorking }
        #expect(model.queueIsPaused)
        heard = []
        model.send("third")
        #expect(fixture.received().count == 1)
        #expect(heard == ["Message queued. The queue is paused; Resume sends it."], "\(heard)")
    }
}
