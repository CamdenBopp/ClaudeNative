import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// A background agent's permission request belongs to that agent, not to
/// the turn it lands in. In real_background_prompt.jsonl one asks to run
/// `touch bg-probe.txt` 11 s into the second turn, and that turn ends 11 s
/// later with it unanswered and no cancel from the CLI. Clearing every
/// request at a turn's end dropped it, and the agent waited for ever.
@MainActor
@Suite(.serialized)
struct BackgroundPromptTests {
    static let requestID = "bfc01e8b-410a-4de2-9199-f2e138c7938e"

    @Test func aBackgroundAgentsRequestOutlivesTheTurnItLandsIn() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bg-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/real_background_prompt.jsonl")
        let script = folder.appending(path: "claude")
        // Each user message gets the captured turn's stdout, up to its result.
        try """
        #!/usr/bin/python3
        import sys, json
        if '--version' in sys.argv:
            print('test-cli'); sys.exit(0)
        turns, turn = [], []
        for l in open('\(fixture.path)'):
            v = json.loads(l)
            if v['dir'] != 'stdout' or v['msg'].get('type') == 'control_response': continue
            turn.append(v['msg'])
            if v['msg'].get('type') == 'result':
                turns.append(turn); turn = []
        for line in sys.stdin:
            if json.loads(line).get('type') == 'user' and turns:
                for msg in turns.pop(0): print(json.dumps(msg), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = AppModel(cliExecutable: script)
        defer { model.close(appIsQuitting: true) }
        model.start(in: folder)
        for _ in 0..<200 where !model.isReady { try await Task.sleep(for: .milliseconds(20)) }
        model.send("Start the background agent.")
        for _ in 0..<300 where model.isWorking || model.transcript.entries.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        model.send("Run sleep 12.")
        for _ in 0..<300 where model.pendingPermission == nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.pendingPermission?.requestID == Self.requestID)
        for _ in 0..<300 where model.isWorking { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isWorking)
        #expect(model.pendingPermission?.requestID == Self.requestID)
    }
}
