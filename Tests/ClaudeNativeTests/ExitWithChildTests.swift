import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// The CLI's exit was reported only once its output also closed, so a
/// process it had started that still held that output (a background job
/// from a hook, say) kept the exit unreported: no "Claude stopped
/// running", no Reconnect, while sends failed.
/// In ProcessExitMidToolTests' suite, which is serialized: both make the
/// app say "Claude stopped running", which the other listens for.
extension ProcessExitMidToolTests {
    @Test func anExitIsReportedThoughAChildHoldsTheOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "exit-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "claude")
        try """
        #!/bin/sh
        case " $* " in *" --version "*) echo test-cli; exit 0;; esac
        sleep 300 &
        echo $! > "$(dirname "$0")/child"
        sleep 0.5
        exit 3
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = AppModel(cliExecutable: script)
        defer { model.close(appIsQuitting: true) }
        let childFile = folder.appending(path: "child")
        func childPid() -> Int32? {
            (try? String(contentsOf: childFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        // Declared before the folder's removal runs, so it reads the pid
        // first; also kills the child when the wait below fails.
        defer { if let child = childPid() { kill(child, SIGKILL) } }
        model.start(in: folder)
        // Not timed: hosted suites alongside can hold the main actor for
        // seconds. Reported before the output closed means reported while
        // the child holding it still runs.
        for _ in 0..<1500 where !model.cliEnded { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.cliEnded)
        let child = try #require(childPid())
        #expect(kill(child, 0) == 0, "the child holding the output had already exited")
    }
}
