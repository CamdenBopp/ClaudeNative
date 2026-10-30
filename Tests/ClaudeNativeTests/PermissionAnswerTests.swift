import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// An answer belongs to the request it was given for. With two requests
/// queued, a second press meant for the first (a double-click, Escape
/// twice) answered the next one, which hadn't been read out yet.
@MainActor
@Suite(.serialized)
struct PermissionAnswerTests {
    /// A fake claude that asks for two Bash commands when sent a message,
    /// and records the request id of every answer it gets.
    static func fake(in folder: URL) throws -> URL {
        let script = folder.appending(path: "claude")
        try """
        #!/usr/bin/python3
        import sys, json
        from pathlib import Path
        if '--version' in sys.argv:
            print('test-cli')
            sys.exit(0)
        log = Path(sys.argv[0]).parent / 'answers'
        def ask(rid, command):
            print(json.dumps({'type': 'control_request', 'request_id': rid, 'request': {'subtype': 'can_use_tool',
                'tool_name': 'Bash', 'input': {'command': command}, 'tool_use_id': 'tool-' + rid}}), flush=True)
        for line in sys.stdin:
            value = json.loads(line)
            if value.get('type') == 'user':
                ask('first', 'touch a.txt')
                ask('second', 'rm -rf build')
            elif value.get('type') == 'control_response':
                with log.open('a') as f: f.write(value['response']['request_id'] + '\\n')
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test func aSecondAnswerForTheSameRequestDoesNotAnswerTheNext() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "answers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(cliExecutable: try Self.fake(in: folder))
        defer { model.close(appIsQuitting: true) }
        model.start(in: folder)
        for _ in 0..<200 where !model.isReady { try await Task.sleep(for: .milliseconds(20)) }
        model.send("Clean up.")
        for _ in 0..<200 where model.pendingPermission?.requestID != "first" { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.pendingPermission?.requestID == "first")
        // The press that answers the first, and a second meant for it too.
        model.answerPermission(allow: true, for: "first")
        model.answerPermission(allow: true, for: "first")
        try await Task.sleep(for: .milliseconds(500))
        let answered = (try? String(contentsOf: folder.appending(path: "answers"), encoding: .utf8)) ?? ""
        #expect(answered.split(separator: "\n") == ["first"])
        #expect(model.pendingPermission?.requestID == "second")
    }
}
