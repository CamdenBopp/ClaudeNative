import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// An effort chosen mid-reply waits for the reply to end. Stop ends it too,
/// but only a finished turn applied the effort: the next message ran at
/// the old one while the picker showed the new.
extension MessageQueueTests {
    @Test func anEffortChosenMidReplyIsAppliedAfterStop() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        // A fork, so the new effort restarts it without a saved session file.
        model.start(in: fixture.directory, resuming: try fixture.savedSession(), fork: true)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { model.isWorking && fixture.received().count == 1 }
        let other = model.effortChoice == "high" ? "low" : "high"
        model.effortChoice = other
        model.interrupt()
        try await waitFor { !model.isWorking }
        func launches() -> [String] {
            ((try? String(contentsOf: fixture.directory.appending(path: "launches"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        try await waitFor { launches().count == 2 }
        #expect(launches().last?.contains("--effort=\(other)") == true, "\(launches())")
    }
}
