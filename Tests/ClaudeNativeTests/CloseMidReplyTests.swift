import AppKit
import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Closing a window mid-reply interrupts the turn, as switching
/// conversations does, so the CLI saves the reply so far. Quitting still
/// ends the CLI at once.
@MainActor
@Suite(.serialized)
struct CloseMidReplyTests {
    /// A fake claude that writes down an interrupt and answers it.
    static func fake(in folder: URL) throws -> URL {
        let script = folder.appending(path: "claude")
        try """
        #!/usr/bin/python3
        import sys, json
        from pathlib import Path
        log = Path(sys.argv[0]).parent / 'heard'
        for line in sys.stdin:
            value = json.loads(line)
            if value.get('request', {}).get('subtype') == 'interrupt':
                log.write_text('interrupt')
                print(json.dumps({'type': 'result', 'terminal_reason': 'aborted_by_user'}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    static func heard(in folder: URL) -> String? {
        try? String(contentsOf: folder.appending(path: "heard"), encoding: .utf8)
    }

    func startedMidReply() async throws -> (AppModel, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(cliExecutable: try Self.fake(in: folder))
        model.start(in: folder)
        for _ in 0..<200 where !model.isReady { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.isReady)
        model.send("Write a long story.")
        try await Task.sleep(for: .milliseconds(300))
        return (model, folder)
    }

    @Test func closingAWindowMidReplyInterruptsTheTurn() async throws {
        let (model, folder) = try await startedMidReply()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.close()
        for _ in 0..<150 where Self.heard(in: folder) == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(Self.heard(in: folder) == "interrupt")
    }

    /// Before the app quits, a reply underway is interrupted and the quit
    /// waits for its turn to end, so the CLI saves the reply so far.
    @Test func beforeQuittingAReplyUnderwayIsInterrupted() async throws {
        let (model, folder) = try await startedMidReply()
        defer { model.close(appIsQuitting: true); try? FileManager.default.removeItem(at: folder) }
        #expect(model.isWorking)
        await AppModel.interruptRepliesBeforeQuitting()
        #expect(Self.heard(in: folder) == "interrupt")
    }

    /// A window closed mid-reply leaves its CLI finishing the interrupt;
    /// quitting then ends it at once rather than leaving it running after
    /// the app has gone.
    @Test func quittingEndsACLIStillFinishingItsInterrupt() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "orphan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Ignores the interrupt, so its turn never ends within the grace.
        let script = folder.appending(path: "claude")
        try """
        #!/usr/bin/python3
        import sys, os
        from pathlib import Path
        if '--version' in sys.argv:
            print('test-cli')
            sys.exit(0)
        (Path(sys.argv[0]).parent / 'pid').write_text(str(os.getpid()))
        for line in sys.stdin: pass
        import time
        while True: time.sleep(1)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = AppModel(cliExecutable: script)
        model.start(in: folder)
        for _ in 0..<200 where !model.isReady { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.isReady)
        model.send("Write a long story.")
        try await Task.sleep(for: .milliseconds(300))
        let pid = try #require(Int32((try? String(contentsOf: folder.appending(path: "pid"), encoding: .utf8)) ?? ""))
        #expect(kill(pid, 0) == 0, "alive before closing")
        #expect(model.isWorking, "a turn is running")
        model.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(kill(pid, 0) == 0, "still finishing its interrupt")
        // The app delegate, which runs with or without a window open: with
        // the last window closed, nothing else ended it.
        AppDelegate().applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try await Task.sleep(for: .milliseconds(500))
        #expect(kill(pid, 0) != 0)
    }

    /// Reopening a conversation just left mid-reply waits for the old CLI
    /// to finish the interrupt and save the reply, so the new one reads it
    /// and two processes never write the file at once.
    @Test func reopeningAConversationWaitsForItsOldCLI() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Logs when each process starts and when it has finished an
        // interrupt, which takes it a second.
        let script = folder.appending(path: "claude")
        try """
        #!/usr/bin/python3
        import sys, json, time
        from pathlib import Path
        if '--version' in sys.argv:
            print('test-cli')
            sys.exit(0)
        log = Path(sys.argv[0]).parent / 'log'
        def note(what):
            with log.open('a') as f: f.write(f'{what} {time.time()}\\n')
        note('start')
        print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 'reopen-session'}), flush=True)
        for line in sys.stdin:
            value = json.loads(line)
            if value.get('request', {}).get('subtype') == 'interrupt':
                time.sleep(1)
                note('interrupted')
                print(json.dumps({'type': 'result', 'terminal_reason': 'aborted_by_user'}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let file = folder.appending(path: "reopen-session.jsonl")
        try Data().write(to: file)
        let model = AppModel(cliExecutable: script)
        defer { model.close(appIsQuitting: true) }
        model.start(in: folder)
        for _ in 0..<200 where !(model.isReady && model.sessionID == "reopen-session") { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.sessionID == "reopen-session")
        model.send("Write a long story.")
        try await Task.sleep(for: .milliseconds(300))
        model.start(in: folder, resuming: .init(id: "reopen-session", title: "Reopen", lastModified: Date(), fileURL: file))
        func lines() -> [(String, Double)] {
            ((try? String(contentsOf: folder.appending(path: "log"), encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { line in
                    let parts = line.split(separator: " ")
                    return parts.count == 2 ? (String(parts[0]), Double(parts[1]) ?? 0) : nil
                }
        }
        for _ in 0..<200 where lines().filter({ $0.0 == "start" }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let interrupted = try #require(lines().first { $0.0 == "interrupted" }?.1)
        let restarted = try #require(lines().filter { $0.0 == "start" }.dropFirst().first?.1)
        #expect(restarted >= interrupted, "the new CLI started \(interrupted - restarted) s before the old one finished")
    }

    /// The wait covers a CLI that starts exiting the conversation while it
    /// waits: a second window on it switching away then.
    @Test func reopeningAlsoWaitsForACLIThatLeavesWhileItWaits() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "reopen2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "claude")
        try """
        #!/usr/bin/python3
        import sys, json, time, os
        from pathlib import Path
        if '--version' in sys.argv:
            print('test-cli')
            sys.exit(0)
        log = Path(sys.argv[0]).parent / 'log'
        def note(what):
            with log.open('a') as f: f.write(f'{what} {os.getpid()} {time.time()}\\n')
        note('start')
        print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 'shared-session'}), flush=True)
        for line in sys.stdin:
            value = json.loads(line)
            if value.get('request', {}).get('subtype') == 'interrupt':
                time.sleep(1)
                note('interrupted')
                print(json.dumps({'type': 'result', 'terminal_reason': 'aborted_by_user'}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let file = folder.appending(path: "shared-session.jsonl")
        try Data().write(to: file)
        func ready() async throws -> AppModel {
            let model = AppModel(cliExecutable: script)
            model.start(in: folder)
            for _ in 0..<200 where !(model.isReady && model.sessionID == "shared-session") { try await Task.sleep(for: .milliseconds(20)) }
            try #require(model.sessionID == "shared-session")
            model.send("Write a long story.")
            return model
        }
        let first = try await ready(), second = try await ready()
        defer { first.close(appIsQuitting: true); second.close(appIsQuitting: true) }
        try await Task.sleep(for: .milliseconds(300))
        let summary = SessionHistory.SessionSummary(id: "shared-session", title: "Shared", lastModified: Date(), fileURL: file)
        // The first window reopens it: its old CLI starts exiting, and the
        // reopen waits.
        first.start(in: folder, resuming: summary)
        try await Task.sleep(for: .milliseconds(500))
        // While it waits, the second window leaves it too.
        second.start(in: folder)
        func lines() -> [(String, Double)] {
            ((try? String(contentsOf: folder.appending(path: "log"), encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { line in
                    let parts = line.split(separator: " ")
                    return parts.count == 3 ? (String(parts[0]), Double(parts[2]) ?? 0) : nil
                }
        }
        // Two original starts, the second window's new one and the reopen.
        for _ in 0..<300 where lines().filter({ $0.0 == "start" }).count < 4 || lines().filter({ $0.0 == "interrupted" }).count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let lastInterrupted = try #require(lines().filter { $0.0 == "interrupted" }.map(\.1).max())
        let starts = lines().filter { $0.0 == "start" }.map(\.1).sorted()
        let reopened = try #require(starts.last)
        #expect(reopened >= lastInterrupted, "the reopen started \(lastInterrupted - reopened) s before the second CLI had saved")
    }

    /// A session open in one window isn't opened in another from the
    /// sidebar, Command-K or Command-1 to 9: two CLIs would write one file.
    /// Open in New Window already refused; these paths didn't check.
    @Test func aSessionOpenInOneWindowIsntOpenedInAnother() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "twowindows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "claude")
        try """
        #!/usr/bin/python3
        import sys, json
        from pathlib import Path
        if '--version' in sys.argv:
            print('test-cli')
            sys.exit(0)
        with (Path(sys.argv[0]).parent / 'launches').open('a') as f: f.write('launch\\n')
        print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 'one-session'}), flush=True)
        for line in sys.stdin: pass
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let file = folder.appending(path: "one-session.jsonl")
        try Data().write(to: file)
        let first = AppModel(cliExecutable: script), second = AppModel(cliExecutable: script)
        defer { first.close(appIsQuitting: true); second.close(appIsQuitting: true) }
        first.start(in: folder)
        for _ in 0..<200 where first.sessionID != "one-session" { try await Task.sleep(for: .milliseconds(20)) }
        try #require(first.sessionID == "one-session")
        // What the window's open asks before starting it.
        #expect(second.sessionIsOpenElsewhere("one-session"))
        #expect(!first.sessionIsOpenElsewhere("one-session"), "its own window isn't another")
        #expect(!second.sessionIsOpenElsewhere("some-other-session"))
        _ = file
    }

    @Test func quittingEndsTheCLIAtOnce() async throws {
        let (model, folder) = try await startedMidReply()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.close(appIsQuitting: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(Self.heard(in: folder) == nil)
    }
}
