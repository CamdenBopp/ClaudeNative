import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// The status line's context use, through the real CLI wrapper: a 200K
/// Opus 4.6 conversation whose Haiku subagent reported a 1M window.
@MainActor
@Suite(.serialized)
struct ContextWindowWiringTests {
    @Test func theStatusLineUsesTheConversationsWindow() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "two-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/real_two_models.jsonl")
        let script = folder.appending(path: "claude")
        try """
        #!/usr/bin/python3
        import sys, json
        if '--version' in sys.argv:
            print('test-cli'); sys.exit(0)
        lines = [json.loads(l) for l in open('\(fixture.path)')]
        for line in sys.stdin:
            if json.loads(line).get('type') == 'user':
                for value in lines:
                    print(json.dumps(value['msg']), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = AppModel(cliExecutable: script)
        defer { model.close(appIsQuitting: true) }
        model.start(in: folder)
        for _ in 0..<200 where !model.isReady { try await Task.sleep(for: .milliseconds(20)) }
        model.send("Start a subagent.")
        for _ in 0..<300 where model.contextUsage == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.contextUsage?.windowTokens == 200_000)
        #expect(model.contextUsage?.usedTokens == 39_658)
    }
}
