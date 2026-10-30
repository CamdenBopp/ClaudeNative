import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

@MainActor
@Suite(.serialized)
struct TranscriptRestoreTests {
    @Test func anUnreadableHistoryDoesNotStartClaudeOrAcceptNewMessages() async throws {
        let fixture = try MessageQueueTests.Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        let session = SessionHistory.SessionSummary(
            id: "missing-\(UUID().uuidString)", title: "Missing history", lastModified: .now,
            fileURL: fixture.directory.appending(path: "missing.jsonl")
        )
        model.start(in: fixture.directory, resuming: session)
        try await MessageQueueTests().waitFor { model.launchError != nil }
        // The previous implementation reported the error, then launched
        // the fake process and enabled sending anyway.
        try await Task.sleep(for: .milliseconds(600))
        #expect(!model.isReady)
        #expect(!model.canSend)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "launches").path))
        model.send("This must stay out of an unloaded conversation.")
        #expect(model.transcript.entries.isEmpty)
        #expect(model.queuedMessages.isEmpty)
    }

    @Test(arguments: ["", "{broken JSON\n", #"{"type":"custom-title","customTitle":"Previously listed"}"#])
    func aKnownHistoryThatNoLongerHasMessagesDoesNotResumeAsBlank(contents: String) async throws {
        let fixture = try MessageQueueTests.Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        let file = fixture.directory.appending(path: "damaged.jsonl")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let session = SessionHistory.SessionSummary(id: "damaged-\(UUID().uuidString)", title: "Previously listed", lastModified: .now,
                                                    fileURL: file, firstPrompt: "The original prompt was present when listed")
        model.start(in: fixture.directory, resuming: session)
        try await MessageQueueTests().waitFor { model.canRetrySessionLoad || model.isReady }
        #expect(model.canRetrySessionLoad)
        #expect(!model.canSend)
        #expect(model.transcript.entries.isEmpty)
    }

    @Test(arguments: [false, true])
    func retryLoadsTheOriginalSourceAndKeepsTheForkChoice(fork: Bool) async throws {
        let fixture = try MessageQueueTests.Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        let file = fixture.directory.appending(path: "temporarily-unavailable.jsonl")
        let id = "retry-\(UUID().uuidString)"
        let session = SessionHistory.SessionSummary(id: id, title: "Retry history", lastModified: .now, fileURL: file)
        model.start(in: fixture.directory, resuming: session, fork: fork)
        try await MessageQueueTests().waitFor { model.canRetrySessionLoad }
        #expect(model.sessionTitle == "Retry history")

        let (window, host) = AccessibilityHost.window(hosting: ConversationContent(
            model: model, textScale: 1, sendSuggestion: { _ in }, retrySessionLoad: model.retrySessionLoad,
            openFile: { _ in }, openInNewWindow: { _ in }, showChanges: { _ in }
        ), size: NSSize(width: 600, height: 420))
        defer { window.close() }
        let words = AccessibilityHost.descendants(of: host).compactMap { AccessibilityHost.label($0) ?? AccessibilityHost.value($0) }
        #expect(words.contains { $0.contains("Session Not Loaded") })
        #expect(!words.contains("Explain this project"))
        let retry = try #require(AccessibilityHost.descendants(of: host).first {
            AccessibilityHost.role($0) == .button && AccessibilityHost.label($0) == "Retry Loading Session"
        })
        // Repairing the file does not require the refreshed sidebar to
        // rediscover it: the retry action retained its exact source URL.
        try FileManager.default.copyItem(at: Fixtures.directory.appending(path: "history/multimodal.jsonl"), to: file)
        try #require(retry.accessibilityPerformPress?() == true)
        try await MessageQueueTests().waitFor { model.isReady }
        #expect(!model.canRetrySessionLoad)
        #expect(model.launchError == nil)
        #expect(model.transcript.entries.first?.text == "Image attachment (image/webp)")
        try await MessageQueueTests().waitFor { FileManager.default.fileExists(atPath: fixture.directory.appending(path: "launches").path) }
        let launches = try String(contentsOf: fixture.directory.appending(path: "launches"), encoding: .utf8)
        #expect(launches.contains("--resume \(id)"))
        #expect(launches.contains("--fork-session") == fork)
        model.send("Continue after recovery.")
        try await MessageQueueTests().waitFor { fixture.received().count == 1 }
        #expect(model.transcript.entries.count == 5)
    }

    @Test(arguments: [false, true])
    func changingEffortAfterAFailedLoadDoesNotStartAnEmptySession(fork: Bool) async throws {
        let fixture = try MessageQueueTests.Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        let file = fixture.directory.appending(path: "missing-effort.jsonl")
        let id = "retry-effort-\(UUID().uuidString)"
        model.start(in: fixture.directory, resuming: .init(id: id, title: "Retry effort", lastModified: .now, fileURL: file), fork: fork)
        try await MessageQueueTests().waitFor { model.canRetrySessionLoad }
        try FileManager.default.copyItem(at: Fixtures.directory.appending(path: "history/multimodal.jsonl"), to: file)
        model.effortChoice = model.effortChoice == "high" ? "low" : "high"
        try await MessageQueueTests().waitFor { model.isReady }
        try await MessageQueueTests().waitFor { FileManager.default.fileExists(atPath: fixture.directory.appending(path: "launches").path) }
        let launches = try String(contentsOf: fixture.directory.appending(path: "launches"), encoding: .utf8)
        #expect(launches.contains("--resume \(id)"))
        #expect(launches.contains("--fork-session") == fork)
        #expect(model.transcript.entries.count == 4)
    }

    @Test func choosingANewSessionClearsTheFailedRecoveryTarget() async throws {
        let fixture = try MessageQueueTests.Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        model.start(in: fixture.directory, resuming: .init(id: "abandoned-\(UUID().uuidString)", title: "Missing", lastModified: .now,
                                                        fileURL: fixture.directory.appending(path: "missing.jsonl")))
        try await MessageQueueTests().waitFor { model.canRetrySessionLoad }
        model.start(in: fixture.directory)
        try await MessageQueueTests().waitFor { model.isReady }
        model.retrySessionLoad()
        #expect(!model.canRetrySessionLoad)
        #expect(model.isReady)
        #expect(model.transcript.entries.isEmpty)
        #expect(model.sessionTitle == nil)
        try await MessageQueueTests().waitFor { FileManager.default.fileExists(atPath: fixture.directory.appending(path: "launches").path) }
        let launches = try String(contentsOf: fixture.directory.appending(path: "launches"), encoding: .utf8)
        #expect(!launches.contains("--resume"))
    }

    @Test func movingAwayAfterRetryDoesNotAnnounceTheOldSessionAsLoaded() async throws {
        let fixture = try MessageQueueTests.Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        let file = fixture.directory.appending(path: "announcement-retry.jsonl")
        model.start(in: fixture.directory, resuming: .init(id: "announcement-\(UUID().uuidString)", title: "Old retry", lastModified: .now, fileURL: file))
        try await MessageQueueTests().waitFor { model.canRetrySessionLoad }
        try FileManager.default.copyItem(at: Fixtures.directory.appending(path: "history/multimodal.jsonl"), to: file)
        var heard: [String] = []
        let token = Announcer.listen { text, _ in if text == "Session loaded." { heard.append(text) } }
        defer { Announcer.stopListening(token) }
        model.retrySessionLoad()
        try await MessageQueueTests().waitFor { model.isReady }
        model.start(in: fixture.directory)
        try await MessageQueueTests().waitFor { model.isReady }
        try await Task.sleep(for: Announcer.afterFocusMoveDelay + .milliseconds(200))
        #expect(heard.isEmpty, "A delayed confirmation belonged to the session that was left.")
    }

    @Test func multimediaHistoryRestoresAndAcceptsANewTurn() async throws {
        let fixture = try MessageQueueTests.Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        let file = fixture.directory.appending(path: "restore-media.jsonl")
        try FileManager.default.copyItem(at: Fixtures.directory.appending(path: "history/multimodal.jsonl"), to: file)
        let session = SessionHistory.SessionSummary(id: "restore-media", title: "Media history", lastModified: .now, fileURL: file)
        model.start(in: fixture.directory, resuming: session)
        try await MessageQueueTests().waitFor { model.isReady }
        let restored = model.transcript.entries
        #expect(restored.map(\.id) == ["user:media-user", "tool:media-read", "tool:media-search", "user:media-document"])
        #expect(restored.first?.text == "Image attachment (image/webp)")
        #expect(restored[1].output == "Screenshot follows.\nImage attachment (image/png)")
        #expect(restored[2].output == "Tool reference: Read\nTool unavailable.")
        #expect(fixture.received().isEmpty, "Loading history must not send its old prompts again.")

        let (window, host) = AccessibilityHost.window(hosting: TranscriptView(
            transcript: model.transcript, revision: model.transcriptRevision,
            workingDirectory: fixture.directory, isWorking: false, showsToolOutput: true
        ), size: NSSize(width: 720, height: 600))
        defer { window.close() }
        let words = AccessibilityHost.descendants(of: host).compactMap { AccessibilityHost.value($0) }
        #expect(words.contains { $0.contains("You: Image attachment (image/webp)") })
        #expect(words.contains { $0.contains("Screenshot follows.\nImage attachment (image/png)") })
        #expect(words.contains { $0.contains("Document: Report (text/plain)\nThe build passed.") })

        model.send("Continue from those attachments.")
        try await MessageQueueTests().waitFor { fixture.received().count == 1 }
        #expect(Array(model.transcript.entries.prefix(restored.count)) == restored)
        #expect(model.transcript.entries.last?.text == "Continue from those attachments.")
        let launches = try String(contentsOf: fixture.directory.appending(path: "launches"), encoding: .utf8)
        #expect(launches.contains("--resume restore-media"))
    }
}
