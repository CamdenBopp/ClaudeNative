import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Deleting a conversation while another window showing it switches to a
/// different conversation: that window keeps its new CLI, and the CLI it
/// left behind is gone before the file can be deleted.
@MainActor
@Suite(.serialized)
struct ReleaseWhileSwitchingTests {
    /// A claude that ignores SIGTERM, so stopping it takes the full grace.
    static func stubbornCLI() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "claude")
        try "#!/bin/bash\ntrap '' TERM\nwhile true; do sleep 1; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    static func summary(_ id: String, in folder: URL) throws -> SessionHistory.SessionSummary {
        let file = folder.appending(path: "\(id).jsonl")
        let prompt = "Saved release-test conversation"
        let record: JSONValue = .object([
            "type": .string("user"), "uuid": .string("saved-\(id)"),
            "message": .object(["role": .string("user"), "content": .string(prompt)]),
        ])
        try record.line().write(to: file)
        return .init(id: id, title: id, lastModified: Date(), fileURL: file, firstPrompt: prompt)
    }

    /// Running, not just in the process table: a killed process stays
    /// there as a zombie until reaped, and kill(pid, 0) still succeeds.
    /// The model's CLI process once it has started; the launch is async
    /// and slow under the parallel suites.
    func pid(of model: AppModel) async throws -> Int32 {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let pid = await model.cliProcessIdentifier() { return pid }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(await model.cliProcessIdentifier())
    }

    /// Kills every process running this test's stub, found by its unique
    /// path. close() only sends SIGTERM, which the stub ignores, and the
    /// SIGKILL meant to follow the grace never came because the test
    /// process had exited first: about one run in three left a stub
    /// running for good, often the CLI a window started for a new
    /// conversation after its own was deleted.
    static func killAll(running stub: URL) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-KILL", "-f", stub.path]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    func isAlive(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat != SZOMB
    }

    /// Both windows switch to Y while release waits on the first of them,
    /// so whichever it reaches second has switched by then, whatever the
    /// order: neither new CLI may be killed.
    @Test func windowsThatSwitchMidDeleteKeepTheirNewCLIs() async throws {
        let stub = try Self.stubbornCLI()
        setenv(CLILocator.environmentOverride, stub.path, 1)
        defer { unsetenv(CLILocator.environmentOverride) }
        // Declared before the windows, so it runs after their close().
        defer {
            Self.killAll(running: stub)
            try? FileManager.default.removeItem(at: stub.deletingLastPathComponent())
        }
        let folder = FileManager.default.temporaryDirectory
        let x = try Self.summary(UUID().uuidString.lowercased(), in: stub.deletingLastPathComponent())
        let y = try Self.summary(UUID().uuidString.lowercased(), in: stub.deletingLastPathComponent())
        let deleter = AppModel(), a = AppModel(), b = AppModel()
        defer { deleter.close(); a.close(); b.close() }
        a.start(in: folder, resuming: x)
        b.start(in: folder, resuming: x)
        try await Task.sleep(for: .milliseconds(500))
        let leftBehind = [try await pid(of: a), try await pid(of: b)]
        let release = Task { await AppModel.release(x.id, from: deleter, startNewHere: {}) }
        // Release is now waiting on the first window's stubborn CLI.
        try await Task.sleep(for: .milliseconds(300))
        a.start(in: folder, resuming: y)
        b.start(in: folder, resuming: y)
        try await Task.sleep(for: .milliseconds(300))
        let moved = [try await pid(of: a), try await pid(of: b)]
        #expect(await release.value)
        AppModel.finishedDeleting(x.id)
        #expect(a.sessionID == y.id && b.sessionID == y.id)
        #expect(moved.allSatisfy(isAlive), "a switched window's CLI for Y was killed")
        #expect(!leftBehind.contains(where: isAlive), "an old CLI for X was still running when release returned")
    }

    /// One window switches while release waits; run once with each window
    /// switching, since only the one release reaches second showed the bug.
    @Test(arguments: [0, 1])
    func oneWindowThatSwitchesMidDeleteKeepsItsNewCLI(switching: Int) async throws {
        let stub = try Self.stubbornCLI()
        setenv(CLILocator.environmentOverride, stub.path, 1)
        defer { unsetenv(CLILocator.environmentOverride) }
        // Declared before the windows, so it runs after their close().
        defer {
            Self.killAll(running: stub)
            try? FileManager.default.removeItem(at: stub.deletingLastPathComponent())
        }
        let folder = FileManager.default.temporaryDirectory
        let x = try Self.summary(UUID().uuidString.lowercased(), in: stub.deletingLastPathComponent())
        let y = try Self.summary(UUID().uuidString.lowercased(), in: stub.deletingLastPathComponent())
        let deleter = AppModel(), a = AppModel(), b = AppModel()
        defer { deleter.close(); a.close(); b.close() }
        a.start(in: folder, resuming: x)
        b.start(in: folder, resuming: x)
        try await Task.sleep(for: .milliseconds(500))
        let mover = switching == 0 ? a : b
        let leftBehind = try await pid(of: mover)
        let release = Task { await AppModel.release(x.id, from: deleter, startNewHere: {}) }
        try await Task.sleep(for: .milliseconds(300))
        mover.start(in: folder, resuming: y)
        try await Task.sleep(for: .milliseconds(300))
        let moved = try await pid(of: mover)
        #expect(await release.value)
        AppModel.finishedDeleting(x.id)
        #expect(mover.sessionID == y.id)
        #expect(isAlive(moved), "the switched window's CLI for Y was killed")
        #expect(!isAlive(leftBehind), "its old CLI for X was still running when release returned")
    }
}
