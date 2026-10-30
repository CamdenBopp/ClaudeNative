import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// View > Announce What Claude Is Doing decides whether the CLI's status
/// lines are spoken. ActivityAnnouncementsTests covers the wording; this
/// covers the setting, through a real AppModel and process.
@MainActor
@Suite(.serialized)
struct ActivityAnnouncementGateTests {
    static let spoken = ["Compacting conversation.", "Conversation compacted.", "Running echo hi."]

    /// A fake claude that answers a message with the status lines CLI
    /// 2.1.310 sent for /compact and a step (the step's line twice, as the
    /// CLI can), then ends the turn.
    static func fake(in folder: URL) throws -> URL {
        let script = folder.appending(path: "claude")
        try """
        #!/usr/bin/python3
        import sys, json
        if '--version' in sys.argv:
            print('test-cli')
            sys.exit(0)
        def emit(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            if json.loads(line).get('type') != 'user': continue
            emit({'type': 'system', 'subtype': 'status', 'status': 'compacting', 'session_id': 'gate'})
            emit({'type': 'system', 'subtype': 'status', 'status': None, 'compact_result': 'success', 'session_id': 'gate'})
            emit({'type': 'system', 'subtype': 'task_summary', 'detail': 'Running echo hi', 'session_id': 'gate'})
            emit({'type': 'system', 'subtype': 'task_summary', 'detail': 'Running echo hi', 'session_id': 'gate'})
            emit({'type': 'system', 'subtype': 'task_summary', 'detail': None, 'session_id': 'gate'})
            emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'done', 'session_id': 'gate'})
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Everything announced during one turn with the setting as given.
    func heard(announcing: Bool) async throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = ActivityAnnouncements.defaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(announcing, forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        var heard: [String] = []
        let listener = Announcer.listen { text, _ in heard.append(text) }
        defer { Announcer.stopListening(listener) }
        let model = AppModel(cliExecutable: try Self.fake(in: folder))
        defer { model.close(appIsQuitting: true) }
        model.start(in: folder)
        for _ in 0..<200 where !model.isReady { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.isReady)
        model.send("/compact")
        for _ in 0..<200 where !model.isWorking { try await Task.sleep(for: .milliseconds(20)) }
        for _ in 0..<200 where model.isWorking { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!model.isWorking)
        return heard.filter { Self.spoken.contains($0) }
    }

    @Test func onSpeaksEachLineOnceInOrder() async throws {
        #expect(try await heard(announcing: true) == Self.spoken)
    }

    @Test func offSpeaksNone() async throws {
        #expect(try await heard(announcing: false) == [])
    }
}
