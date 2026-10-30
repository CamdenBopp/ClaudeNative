import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Accepting a plan takes the CLI out of Plan mode (real_plan_accept.jsonl:
/// the next turn's init reports "default"), but the app only learned the
/// mode at launch: the Mode menu still said Plan, choosing Plan sent
/// nothing, and a restart relaunched with --permission-mode=plan.
@MainActor
@Suite(.serialized)
struct PlanModeSyncTests {
    @Test func theModeFollowsWhatTheCLIReports() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "plan-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/real_plan_accept.jsonl")
        let script = folder.appending(path: "claude")
        // Each user message gets the captured turn's stdout, up to its result.
        try """
        #!/usr/bin/python3
        import sys, json
        from pathlib import Path
        if '--version' in sys.argv:
            print('test-cli'); sys.exit(0)
        turns, turn = [], []
        for l in open('\(fixture.path)'):
            v = json.loads(l)
            if v['dir'] != 'stdout' or v['msg'].get('type') in ('control_response', 'control_request'): continue
            turn.append(v['msg'])
            if v['msg'].get('type') == 'result':
                turns.append(turn); turn = []
        sent = Path(sys.argv[0]).parent / 'controls'
        for line in sys.stdin:
            value = json.loads(line)
            if value.get('type') == 'control_request':
                with sent.open('a') as f: f.write(value['request'].get('subtype', '') + '\\n')
            if value.get('type') == 'user' and turns:
                for msg in turns.pop(0): print(json.dumps(msg), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = AppModel(cliExecutable: script)
        defer { model.close(appIsQuitting: true) }
        model.permissionModeChoice = "plan"
        model.start(in: folder)
        for _ in 0..<200 where !model.isReady { try await Task.sleep(for: .milliseconds(20)) }
        model.send("Plan it.")
        for _ in 0..<300 where model.isWorking || model.transcript.entries.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.permissionMode == "plan")
        model.send("Reply with just ok.")
        for _ in 0..<300 where model.permissionMode == "plan" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.permissionMode == "default")
        try await Task.sleep(for: .milliseconds(200))
        // Taken from the CLI, not sent back to it.
        let controls = (try? String(contentsOf: folder.appending(path: "controls"), encoding: .utf8)) ?? ""
        #expect(!controls.contains("set_permission_mode"), "\(controls)")
    }
}
