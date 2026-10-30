import Foundation
import Testing
@testable import ClaudeNativeCore

/// The terminal panel's shell: it runs on a terminal of its own in the
/// folder, and Control-C reaches what's running.
@Suite(.serialized) struct TerminalSessionTests {
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private(set) var ended = false
        func add(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }
        func end() { lock.lock(); ended = true; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
        var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    }

    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func runsOnATerminalInTheFolder() async throws {
        let collected = Collected()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        let session = try TerminalSession(in: folder, shell: "/bin/sh", arguments: ["-c", "pwd; test -t 0 && echo tty"],
                                          output: collected.add, ended: collected.end)
        try await waitFor { collected.isEnded }
        session.terminate()
        var text = TerminalText(); text.append(collected.value)
        let lines = text.shown.split(separator: "\n").map(String.init)
        #expect(lines.contains("tty"))
        #expect(lines.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == folder.resolvingSymlinksInPath().path.replacingOccurrences(of: "/$", with: "", options: .regularExpression))
    }

    @Test func controlCInterruptsTheRunningCommand() async throws {
        let collected = Collected()
        let session = try TerminalSession(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "echo started; sleep 20; echo after"],
                                          output: collected.add, ended: collected.end)
        try await waitFor { collected.value.contains("started") }
        let sent = Date()
        session.interrupt()
        try await waitFor { collected.isEnded }
        session.terminate()
        #expect(collected.isEnded)
        #expect(Date().timeIntervalSince(sent) < 3)
        #expect(!collected.value.contains("after"))
    }

    /// The shell gets the terminal and nothing else the app has open. It
    /// inherited every descriptor, so a git pipe open when it started kept
    /// its write end: the Changes panel waited for git's output to end
    /// until the shell quit, stuck on "Reading changes…" (a 46-second
    /// test failure under load on 2026-10-27).
    @Test func theShellDoesNotKeepTheAppsPipesOpen() async throws {
        let pipe = Pipe()
        let session = try TerminalSession(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "sleep 10"], output: { _ in })
        defer { session.terminate() }
        try pipe.fileHandleForWriting.close()
        // With the only writer closed, the read end reports end of file.
        var poller = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, Self.endOfFileWaitMilliseconds)
        #expect(ready == 1, "the shell still holds the pipe's write end")
        if ready == 1 { #expect(pipe.fileHandleForReading.availableData.isEmpty) }
    }

    static let endOfFileWaitMilliseconds: Int32 = 2000

    /// The processes `parent` started (proc_listchildpids returns a count).
    static func children(of parent: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let found = proc_listchildpids(parent, &pids, Int32(64 * MemoryLayout<pid_t>.size))
        return found > 0 ? Array(pids.prefix(Int(found))).filter { $0 > 0 } : []
    }

    /// In an interactive zsh, Interrupt stops the running command and the
    /// shell carries on.
    @Test func interruptStopsACommandInAnInteractiveShell() async throws {
        let collected = Collected()
        let session = try TerminalSession(in: URL(fileURLWithPath: "/tmp"), shell: "/bin/zsh", arguments: ["-f", "-i"], output: collected.add)
        defer { session.terminate() }
        try await waitFor { collected.value.contains("%") || collected.value.contains("#") }
        session.send("sleep 30\r")
        try await waitFor { !Self.children(of: session.processIdentifier).isEmpty }
        #expect(!Self.children(of: session.processIdentifier).isEmpty)
        session.interrupt()
        try await waitFor { Self.children(of: session.processIdentifier).isEmpty }
        #expect(Self.children(of: session.processIdentifier).isEmpty, "the sleep is still running")
        #expect(kill(session.processIdentifier, 0) == 0, "the shell should survive")
    }

    /// The terminal is the shell's controlling terminal, as in Terminal, so
    /// Control-C typed into it is the terminal driver's to deliver.
    @Test func theTerminalIsTheShellsControllingTerminal() async throws {
        let collected = Collected()
        let session = try TerminalSession(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "ps -o tty= -p $$"],
                                          output: collected.add, ended: collected.end)
        try await waitFor { collected.isEnded }
        session.terminate()
        let tty = collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(tty.hasPrefix("ttys"), "controlling terminal: \(tty)")
    }

    /// A session whose shell has exited and been reaped doesn't signal its
    /// old process id, which can belong to another process by then.
    @Test func terminatingAfterTheShellExitedSignalsNothing() async throws {
        let collected = Collected()
        let session = try TerminalSession(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "true"],
                                          output: collected.add, ended: collected.end)
        try await waitFor { collected.isEnded }
        let sent = Collected()
        let saved = TerminalSession.sendSignal
        TerminalSession.sendSignal = { pid, signal in sent.add("\(pid):\(signal) "); return 0 }
        defer { TerminalSession.sendSignal = saved }
        session.terminate()
        session.terminate()
        #expect(sent.value.isEmpty, "signalled \(sent.value)")
    }

    /// Ending the session ends what the shell started too, not just the
    /// shell: a sleep it ran kept going for its full 30 seconds after the
    /// panel stopped (seen in the test suite).
    @Test func terminateEndsWhatTheShellStarted() async throws {
        let collected = Collected()
        let session = try TerminalSession(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "/bin/sleep 30; echo done"],
                                          output: collected.add, ended: collected.end)
        try await waitFor { !Self.children(of: session.processIdentifier).isEmpty }
        let sleeper = try #require(Self.children(of: session.processIdentifier).first)
        session.terminate()
        try await waitFor { kill(sleeper, 0) != 0 }
        #expect(kill(sleeper, 0) != 0, "the sleep \(sleeper) outlived the session")
    }

    /// Lines typed for a program that isn't reading its input fill the
    /// terminal's buffer; the next write then waited, on the main thread,
    /// until the program read or exited: the whole app hung.
    @Test func sendingNeverWaitsForTheProgramToRead() throws {
        let session = try TerminalSession(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "sleep 4"], output: { _ in })
        defer { session.terminate() }
        let line = String(repeating: "x", count: 100) + "\n"
        let elapsed = ContinuousClock().measure {
            for _ in 0..<40 { session.send(line) }
        }
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
    }

    /// Control-C still reaches the program when typed lines are waiting
    /// for it to read: behind them in the queue, it never went.
    @Test func interruptGetsThroughAFullBuffer() async throws {
        let collected = Collected()
        let session = try TerminalSession(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "sleep 30"],
                                          output: { _ in }, ended: { collected.end() })
        defer { session.terminate() }
        let line = String(repeating: "x", count: 100) + "\n"
        for _ in 0..<40 { session.send(line) }
        try await Task.sleep(for: .milliseconds(300))
        session.interrupt()
        try await waitFor { collected.isEnded }
        #expect(collected.isEnded)
    }

    /// Ending a session (closing the window, changing its folder) left the
    /// shell a zombie until the app quit: the only waitpid that would reap
    /// it was in the reader that ending had just cancelled.
    @Test func anEndedSessionLeavesNoZombie() async throws {
        let session = try TerminalSession(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "sleep 30"], output: { _ in })
        let pid = session.processIdentifier
        try await Task.sleep(for: .milliseconds(200))
        session.terminate()
        // Reaped, the id is gone: kill(pid, 0) fails with ESRCH. A zombie
        // still answers it.
        try await waitFor { kill(pid, 0) != 0 }
        let state = { () -> String in let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "stat=,comm=", "-p", "\(pid)"]; let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit(); return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }()
        #expect(kill(pid, 0) != 0 && errno == ESRCH, "\(state)")
    }

    /// An app opened from the Finder has no LANG, and the shell inherited
    /// none: on a terminal, ls showed café.txt as "caf??.txt", which
    /// VoiceOver read so. One the user set is kept.
    @Test func theShellGetsAUTF8LanguageWhenTheAppHasNone() {
        let us = Locale(identifier: "en_US")
        #expect(TerminalSession.environment(from: [:], shell: "/bin/zsh", locale: us)["LANG"] == "en_US.UTF-8")
        #expect(TerminalSession.environment(from: ["LANG": "fr_FR.UTF-8"], shell: "/bin/zsh", locale: us)["LANG"] == "fr_FR.UTF-8")
        // A locale with no region still gets a working UTF-8 language.
        #expect(TerminalSession.environment(from: [:], shell: "/bin/zsh", locale: Locale(identifier: "de"))["LANG"] == "en_US.UTF-8")
    }
}
