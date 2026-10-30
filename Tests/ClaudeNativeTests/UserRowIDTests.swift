import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Your message's row is called by the uuid the CLI saves it under, so the
/// same row reopened from the file keeps its id: the reading place and
/// marks on it were lost on every reload (switching back, an effort
/// change, a reconnect). The CLI saves the uuid a user line carries (seen
/// with the real CLI).
extension MessageQueueTests {
    @Test func theUserRowIsKeyedByTheUUIDTheCLIGets() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { fixture.received().count == 1 }
        let sent = try #require(fixture.received().first?["uuid"]?.string)
        let row = try #require(model.transcript.entries.first { $0.kind == .user })
        #expect(row.id == "user:\(sent)")
        try fixture.finish(1)
        try await waitFor { !model.isWorking }
    }
}
