import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// The CLI dying mid-turn, while a tool runs. Its output so far is the real
/// capture of a Bash `sleep` starting (real_interrupt_running_tool.jsonl,
/// through task_started); then the process exits instead of being stopped.
@MainActor
@Suite(.serialized)
struct ProcessExitMidToolTests {
    static func fake(in folder: URL) throws -> URL {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/real_interrupt_running_tool.jsonl")
        let script = folder.appending(path: "claude")
        try """
        #!/usr/bin/python3
        import sys, json, time
        if '--version' in sys.argv:
            print('test-cli')
            sys.exit(0)
        lines = [json.loads(l) for l in open('\(fixture.path)')]
        for line in sys.stdin:
            if json.loads(line).get('type') == 'user':
                for n, value in enumerate(lines[:19], start=1):
                    if value['dir'] == 'stdout' and n >= 4:
                        print(json.dumps(value['msg']), flush=True)
                time.sleep(0.3)
                sys.exit(1)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test func aToolRunningWhenTheCLIExitsIsNoLongerRunningAndOneThingIsSaid() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "exit-mid-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(cliExecutable: try Self.fake(in: folder))
        defer { model.close(appIsQuitting: true) }
        var urgent: [String] = []
        // Only the lines a CLI exit can cause: suites running alongside
        // announce too.
        let listener = Announcer.listen { text, urgency in
            if urgency == .urgent, text.hasPrefix("Claude stopped running") || text.hasPrefix("Error: Claude exited") { urgent.append(text) }
        }
        defer { Announcer.stopListening(listener) }
        model.start(in: folder)
        for _ in 0..<200 where !model.isReady { try await Task.sleep(for: .milliseconds(20)) }
        model.send("Run sleep 20.")
        for _ in 0..<300 where !model.cliEnded { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.cliEnded)
        // Published on the next run loop pass.
        try await Task.sleep(for: .milliseconds(200))
        let tools = model.transcript.entries.filter { if case .tool = $0.kind { true } else { false } }
        try #require(!tools.isEmpty)
        for tool in tools {
            if case .tool(_, let status) = tool.kind { #expect(status != .running, "\(tool.text)") }
        }
        // "Claude stopped running…" alone: a second urgent line cut it off.
        #expect(urgent.count == 1, "\(urgent)")
        #expect(urgent.first?.hasPrefix("Claude stopped running") == true)
        #expect(!model.isWorking)
    }
}
