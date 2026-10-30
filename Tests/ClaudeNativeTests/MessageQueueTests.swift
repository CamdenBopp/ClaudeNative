import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Exercise the real AppModel and stream-json transport without contacting
/// a service. A marker completes each fake turn, so dispatch is deterministic.
@MainActor
@Suite(.serialized)
struct MessageQueueTests {
    struct Fixture {
        let directory: URL
        let executable: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "message-queue-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            executable = directory.appending(path: "claude")
            try Self.script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        func received(in folder: URL? = nil) -> [JSONValue] {
            let file = (folder ?? directory).appending(path: "received.jsonl")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
        }

        /// A resumable conversation needs real history. Sidebar-only
        /// examples point at /dev/null and deliberately have no messages.
        func savedSession() throws -> SessionHistory.SessionSummary {
            let id = UUID().uuidString
            let file = directory.appending(path: "\(id).jsonl")
            let prompt = "Saved conversation prompt"
            let record: JSONValue = .object([
                "type": .string("user"), "uuid": .string("saved-\(id)"),
                "message": .object(["role": .string("user"), "content": .string(prompt)]),
            ])
            try record.line().write(to: file)
            return .init(id: id, title: "Saved conversation", lastModified: .now, fileURL: file, firstPrompt: prompt)
        }

        func finish(_ index: Int, error: Bool = false) throws {
            try (error ? "error" : "success").write(to: directory.appending(path: "finish-\(index)"), atomically: true, encoding: .utf8)
        }

        static let script = #"""
        #!/usr/bin/python3
        import sys, os, json, select, time
        from pathlib import Path
        if '--version' in sys.argv:
            print('test-cli')
            sys.exit(0)
        root = Path.cwd()
        with (root / 'launches').open('a') as launches:
            launches.write(' '.join(sys.argv[1:]) + '\n')
        received = root / 'received.jsonl'
        count = len(received.read_text().splitlines()) if received.exists() else 0
        active = None
        pending = b''
        def emit(value):
            print(json.dumps(value), flush=True)
        while True:
            if (root / 'exit').exists():
                sys.exit(1)
            if (root / 'close-input').exists():
                os.close(sys.stdin.fileno())
                (root / 'input-closed').touch()
                while True:
                    time.sleep(0.01)
            readable, _, _ = select.select([sys.stdin], [], [], 0.01)
            if readable:
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    break
                pending += data
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    value = json.loads(line)
                    if value.get('type') == 'user':
                        count += 1
                        active = count
                        with received.open('a') as output:
                            output.write(json.dumps(value) + '\n')
                    elif value.get('request', {}).get('subtype') == 'interrupt':
                        active = None
                        emit({'type': 'result', 'terminal_reason': 'aborted_by_user'})
            if active is not None and (root / ('finish-' + str(active))).exists():
                failed = (root / ('finish-' + str(active))).read_text() == 'error'
                active = None
                emit({'type': 'result', 'is_error': failed, 'subtype': 'error' if failed else 'success', 'result': 'test turn'})
        """#
    }

    func waitFor(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // Count actual polling opportunities: other hosted AppKit tests
        // can occupy the main actor for longer than a wall-clock timeout.
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Reported at the caller's line, so a timeout says which wait.
        try #require(condition(), "Timed out waiting for the fake CLI", sourceLocation: sourceLocation)
    }

    @Test func editsAndCancellationStayLocalUntilThePreviousTurnFinishes() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { fixture.received().count == 1 }
        let image = ImageAttachment(name: "sample.png", mediaType: "image/png", data: Data([1, 2, 3]))
        model.send("second", images: [image])
        model.send("third")
        #expect(model.queuedMessages.count == 2)
        #expect(model.transcript.entries.filter { $0.kind == .user }.map(\.text) == ["first"])
        let second = try #require(model.queuedMessages.first?.id)
        let third = try #require(model.queuedMessages.last?.id)
        model.beginEditingQueuedMessage(second)
        try fixture.finish(1)
        try await waitFor { !model.isWorking }
        #expect(fixture.received().count == 1)
        model.updateQueuedMessage(second, text: "edited second")
        // What the model was doing if this stalls (it has, once, in a slow
        // full-suite run).
        for _ in 0..<500 where fixture.received().count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        try #require(fixture.received().count == 2, "working \(model.isWorking), ready \(model.isReady), paused \(model.queueIsPaused), editing \(String(describing: model.editingQueuedMessageID)), queued \(model.queuedMessages.map(\.text)), error \(model.launchError ?? "none")")
        let blocks = try #require(fixture.received().last?["message"]?["content"]?.array)
        #expect(blocks.last?["text"]?.string == "edited second")
        #expect(blocks.first?["source"]?["data"]?.string == image.data.base64EncodedString())
        model.cancelQueuedMessage(third)
        try fixture.finish(2)
        try await waitFor { !model.isWorking }
        #expect(fixture.received().count == 2)
        #expect(model.queuedMessages.isEmpty)
    }

    @Test func stopPausesRemainingMessagesUntilExplicitResume() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { fixture.received().count == 1 }
        model.send("second")
        model.interrupt()
        try await waitFor { !model.isWorking }
        #expect(model.queueIsPaused)
        model.send("third")
        #expect(fixture.received().count == 1)
        #expect(model.queuedMessages.map(\.text) == ["second", "third"])
        model.resumeQueuedMessages()
        try await waitFor { fixture.received().count == 2 }
        try fixture.finish(2)
        // What the model was doing if this stalls (it has, rarely, in full
        // suite runs).
        for _ in 0..<500 where fixture.received().count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(fixture.received().count == 3, "working \(model.isWorking), ready \(model.isReady), paused \(model.queueIsPaused), queued \(model.queuedMessages.map(\.text)), received \(fixture.received().count), error \(model.launchError ?? "none")")
        try #require(fixture.received().count == 3)
        #expect(fixture.received().last?["message"]?["content"]?.array?.last?["text"]?.string == "third")
        try fixture.finish(3)
        try await waitFor { !model.isWorking }
        #expect(model.queuedMessages.isEmpty)
    }

    @Test func anErrorPausesTheQueueAndSwitchingFoldersClearsIt() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { fixture.received().count == 1 }
        model.send("old queued message")
        try fixture.finish(1, error: true)
        try await waitFor { !model.isWorking }
        #expect(model.queueIsPaused)
        #expect(fixture.received().count == 1)
        let other = fixture.directory.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        model.start(in: other)
        try await waitFor { model.isReady }
        #expect(model.queuedMessages.isEmpty)
        model.send("new conversation")
        try await waitFor { fixture.received(in: other).count == 1 }
        #expect(fixture.received(in: other).first?["message"]?["content"]?.array?.last?["text"]?.string == "new conversation")
    }

    @Test func aProcessExitKeepsPendingMessagesForReconnect() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { fixture.received().count == 1 }
        model.send("second")
        let exit = fixture.directory.appending(path: "exit")
        try Data().write(to: exit)
        try await waitFor { !model.isReady }
        #expect(model.queueIsPaused)
        #expect(model.queuedMessages.map(\.text) == ["second"])
        try FileManager.default.removeItem(at: exit)
        model.resumeQueuedMessages()
        try await waitFor { fixture.received().count == 2 }
        #expect(fixture.received().last?["message"]?["content"]?.array?.last?["text"]?.string == "second")
        try fixture.finish(2)
        try await waitFor { !model.isWorking }
    }

    /// Claude ending between turns, with nothing queued, is said out loud,
    /// and the next message starts it again and goes out. The field went
    /// quiet instead: Send disabled, Return doing nothing, nothing heard.
    @Test func aProcessExitWithNothingQueuedSaysSoAndTheNextMessageReconnects() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        var heard: [String] = []
        let listener = Announcer.listen { text, _ in if text.hasPrefix("Claude stopped running") { heard.append(text) } }
        defer { Announcer.stopListening(listener) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        let exit = fixture.directory.appending(path: "exit")
        try Data().write(to: exit)
        try await waitFor { !model.isReady }
        #expect(model.launchError != nil)
        #expect(model.canSend)
        // Once: setting the error already announces it, and a second
        // urgent announcement cut the first off.
        try await Task.sleep(for: .milliseconds(200))
        #expect(heard == ["Claude stopped running. Your next message starts it again."])
        try FileManager.default.removeItem(at: exit)
        model.send("after the exit")
        try await waitFor { fixture.received().count == 1 }
        #expect(fixture.received().last?["message"]?["content"]?.array?.last?["text"]?.string == "after the exit")
        #expect(model.launchError == nil)
        try fixture.finish(1)
        try await waitFor { !model.isWorking }
    }

    /// A reply that ends with nothing sent after it is announced, even
    /// with a message waiting while you edit it; the announcement had
    /// waited for an empty queue.
    @Test func finishingIsAnnouncedWhileTheNextMessageIsBeingEdited() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        var heard: [String] = []
        let listener = Announcer.listen { text, _ in if text == "Claude finished." { heard.append(text) } }
        defer { Announcer.stopListening(listener) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { fixture.received().count == 1 }
        model.send("second")
        let second = try #require(model.queuedMessages.first?.id)
        model.beginEditingQueuedMessage(second)
        try fixture.finish(1)
        try await waitFor { !model.isWorking }
        try await waitFor { !heard.isEmpty }
        #expect(heard == ["Claude finished."])
        #expect(fixture.received().count == 1)
    }

    /// When the next queued message goes straight out, the reply in
    /// between isn't announced as finished.
    @Test func finishingIsNotAnnouncedWhenTheNextMessageGoesOut() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        var heard: [String] = []
        let listener = Announcer.listen { text, _ in if text == "Claude finished." { heard.append(text) } }
        defer { Announcer.stopListening(listener) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { fixture.received().count == 1 }
        model.send("second")
        try fixture.finish(1)
        try await waitFor { fixture.received().count == 2 }
        #expect(heard.isEmpty)
        try fixture.finish(2)
        try await waitFor { !heard.isEmpty }
        #expect(heard == ["Claude finished."])
    }

    /// With sound cues on, the finished chime waits for the last reply:
    /// it played as one reply ended and a queued message went straight out.
    @Test func theFinishChimeWaitsForTheQueuedMessagesReply() async throws {
        let defaults = UserDefaults.standard
        let wasOn = defaults.object(forKey: SoundCuePolicy.defaultsKey)
        defaults.set(true, forKey: SoundCuePolicy.defaultsKey)
        defer { defaults.set(wasOn, forKey: SoundCuePolicy.defaultsKey) }
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        var played: [SoundCue] = []
        model.playCue = { played.append($0) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { fixture.received().count == 1 }
        model.send("second")
        try fixture.finish(1)
        try await waitFor { fixture.received().count == 2 }
        #expect(!played.contains(.turnFinished))
        try fixture.finish(2)
        try await waitFor { played.contains(.turnFinished) }
        #expect(played.filter { $0 == .turnFinished }.count == 1)
    }

    /// A mode granted for this conversation ("Allow edits for this
    /// conversation") survives the CLI starting again for it, as a
    /// reconnect or an effort change does; it went back to the toolbar's
    /// mode and Claude asked again.
    @Test func aReconnectKeepsTheConversationsMode() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        // As answering "Allow edits for this conversation" does.
        model.permissionMode = "acceptEdits"
        let exit = fixture.directory.appending(path: "exit")
        try Data().write(to: exit)
        try await waitFor { !model.isReady }
        try FileManager.default.removeItem(at: exit)
        model.send("after the reconnect")
        try await waitFor { fixture.received().count == 1 }
        let launches = (try? String(contentsOf: fixture.directory.appending(path: "launches"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        #expect(launches.count == 2)
        #expect(launches.last?.contains("--permission-mode=acceptEdits") == true, "\(launches.last ?? "none")")
        #expect(model.permissionMode == "acceptEdits")
        try fixture.finish(1)
        try await waitFor { !model.isWorking }
    }

    /// A fork that hasn't been sent anything has no id of its own yet. A
    /// reconnect then forked nothing: it started a new, empty conversation
    /// and the fork's history was gone. It forks the original again.
    @Test func aReconnectBeforeAForksFirstMessageForksAgain() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        let original = fixture.directory.appending(path: "original.jsonl")
        try Data().write(to: original)
        model.start(in: fixture.directory, resuming: .init(id: "original", title: "Original", lastModified: Date(), fileURL: original), fork: true)
        try await waitFor { model.isReady }
        let exit = fixture.directory.appending(path: "exit")
        try Data().write(to: exit)
        try await waitFor { !model.isReady }
        try FileManager.default.removeItem(at: exit)
        model.send("first message to the fork")
        try await waitFor { fixture.received().count == 1 }
        let launches = (try? String(contentsOf: fixture.directory.appending(path: "launches"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        #expect(launches.count == 2)
        #expect(launches.last?.contains("--resume original --fork-session") == true, "\(launches.last ?? "none")")
        try fixture.finish(1)
        try await waitFor { !model.isWorking }
    }

    @Test func aFailedWriteKeepsTheMessageAndMarksTheAttemptUnsent() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        let marker = fixture.directory.appending(path: "close-input")
        try Data().write(to: marker)
        try await waitFor { FileManager.default.fileExists(atPath: fixture.directory.appending(path: "input-closed").path) }
        model.send("keep this message")
        try await waitFor { !model.isReady }
        #expect(model.queueIsPaused)
        #expect(model.queuedMessages.map(\.text) == ["keep this message"])
        #expect(model.transcript.entries.last?.kind == .notice)
        #expect(model.transcript.entries.last?.text == "Message not sent: keep this message")
        #expect(fixture.received().isEmpty)
        try FileManager.default.removeItem(at: marker)
        model.resumeQueuedMessages()
        try await waitFor { fixture.received().count == 1 }
        #expect(model.transcript.entries.filter { $0.kind == .user }.count == 1)
        #expect(Set(model.transcript.entries.map(\.id)).count == model.transcript.entries.count)
    }

    @Test func aDeferredEffortChangeDoesNotDispatchWithTheOldSetting() async throws {
        let fixture = try Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        model.start(in: fixture.directory)
        try await waitFor { model.isReady }
        model.send("first")
        try await waitFor { fixture.received().count == 1 }
        model.effortChoice = "high"
        model.send("next, at high effort")
        try fixture.finish(1)
        // This fake CLI has no saved session to resume with --effort. The
        // queue must pause instead of silently using the old process.
        try await waitFor { model.queueIsPaused }
        #expect(fixture.received().count == 1)
        #expect(model.queuedMessages.map(\.text) == ["next, at high effort"])
    }
}
