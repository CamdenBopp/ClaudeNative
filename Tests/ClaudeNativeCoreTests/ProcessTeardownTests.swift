import Foundation
import Testing
@testable import ClaudeNativeCore

/// A fake claude that ignores SIGTERM, as a hung CLI might.
struct ProcessTeardownTests {
    func stubbornCLI() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "stubborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "claude")
        try "#!/bin/bash\ntrap '' TERM\nwhile true; do sleep 1; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    @Test func stopKillsACLIThatIgnoresSIGTERM() async throws {
        let cli = ClaudeCLI(executable: try stubbornCLI(), workingDirectory: FileManager.default.temporaryDirectory)
        try await cli.start()
        let pid = try #require(await cli.processIdentifier)
        try await Task.sleep(for: .milliseconds(300))
        await cli.stop()
        try await Task.sleep(for: .milliseconds(500))
        #expect(isAlive(pid), "SIGTERM alone should not have ended the stub")
        try await Task.sleep(for: .seconds(ClaudeCLI.killGrace + 1))
        #expect(!isAlive(pid))
    }

    @Test func terminateNowKillsWithinTheGrace() async throws {
        let cli = ClaudeCLI(executable: try stubbornCLI(), workingDirectory: FileManager.default.temporaryDirectory)
        try await cli.start()
        let pid = try #require(await cli.processIdentifier)
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        cli.terminateNow()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!isAlive(pid))
        #expect(Date().timeIntervalSince(started) < ClaudeCLI.killGrace + 1)
    }

    /// Deleting the open conversation waits for its CLI to be gone, so the
    /// CLI can't write the file again once it's in the Trash.
    @Test func stopAndWaitReturnsOnlyOnceTheCLIHasExited() async throws {
        let cli = ClaudeCLI(executable: try stubbornCLI(), workingDirectory: FileManager.default.temporaryDirectory)
        try await cli.start()
        let pid = try #require(await cli.processIdentifier)
        try await Task.sleep(for: .milliseconds(300))
        await cli.stopAndWait()
        #expect(!isAlive(pid))
    }

    /// Leaving a conversation mid-reply interrupts the turn before ending
    /// the CLI, as Stop does, so the reply so far is saved. Terminated
    /// straight away, the CLI saved none of it: a session left 8 s into a
    /// reply reopened with your message alone (0 characters of reply in
    /// its file, against 1,789 after Stop, live on 2026-10-27).
    @Test func stopAndWaitInterruptsARunningTurnFirst() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "interrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "claude")
        try """
        #!/usr/bin/python3
        import sys, json, os
        from pathlib import Path
        log = Path(sys.argv[0]).parent / 'heard'
        for line in sys.stdin:
            value = json.loads(line)
            if value.get('request', {}).get('subtype') == 'interrupt':
                log.write_text('interrupt')
                print(json.dumps({'type': 'result', 'terminal_reason': 'aborted_by_user'}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cli = ClaudeCLI(executable: script, workingDirectory: folder)
        try await cli.start()
        let pid = try #require(await cli.processIdentifier)
        try await cli.send("Write a long story.")
        try await Task.sleep(for: .milliseconds(300))
        await cli.stopAndWait()
        #expect((try? String(contentsOf: folder.appending(path: "heard"), encoding: .utf8)) == "interrupt")
        #expect(!isAlive(pid))
    }

    /// A CLI that has closed its input but not yet exited (crashing, say)
    /// fails the send with an error. Writing to it raised SIGPIPE, which
    /// ends any process that hasn't chosen to ignore it: the test runner
    /// died of it ("unexpected signal code 13").
    @Test func sendingToACLIThatClosedItsInputThrows() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "closed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "claude")
        try "#!/bin/bash\nexec 0<&-\nsleep 5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cli = ClaudeCLI(executable: script, workingDirectory: FileManager.default.temporaryDirectory)
        try await cli.start()
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: (any Error).self) {
            // The pipe's buffer takes the first writes; enough to fill it.
            for _ in 0..<64 { try await cli.send(String(repeating: "x", count: 4096)) }
        }
        cli.terminateNow()
    }

    /// A model or mode chosen before the process has started (a saved
    /// session still loading) is the one it starts with; the change failed
    /// with "Claude isn't running" and the old mode stayed in force.
    @Test func aModelOrModeChosenBeforeStartingIsTheOneItStartsWith() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "args-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "claude")
        try "#!/bin/sh\n[ \"$1\" = --version ] && { echo test-cli; exit 0; }\necho \"$@\" > \"$(dirname \"$0\")/args\"\nexec cat > /dev/null\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cli = ClaudeCLI(executable: script, workingDirectory: folder, model: "sonnet", permissionMode: "acceptEdits")
        try await cli.setPermissionMode("plan")
        try await cli.setModel("opus")
        try await cli.start()
        defer { cli.terminateNow() }
        var args = ""
        for _ in 0..<100 where args.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            args = (try? String(contentsOf: folder.appending(path: "args"), encoding: .utf8)) ?? ""
        }
        #expect(args.contains("--permission-mode=plan"), "\(args)")
        #expect(args.contains("--model=opus"), "\(args)")
    }
}

