import Foundation
import Testing
@testable import ClaudeNativeCore

struct ShellPathTests {
    @Test func findsThePathBetweenMarkersDespiteStartupNoise() {
        let output = "Welcome!\nlast login...\(ShellPath.startMarker)/opt/homebrew/bin:/usr/bin\(ShellPath.endMarker)bye"
        #expect(ShellPath.extract(from: output) == "/opt/homebrew/bin:/usr/bin")
        #expect(ShellPath.extract(from: "no markers here") == nil)
    }

    @Test func loginEntriesComeFirstAndEachDirectoryOnce() {
        let merged = ShellPath.merged(login: "/Users/x/.cargo/bin:/opt/homebrew/bin:/usr/bin", inherited: "/usr/bin:/bin", home: "/Users/x")
        let parts = merged.split(separator: ":").map(String.init)
        #expect(Array(parts.prefix(3)) == ["/Users/x/.cargo/bin", "/opt/homebrew/bin", "/usr/bin"])
        #expect(parts.count == Set(parts).count)
        #expect(parts.contains("/Users/x/.local/bin"))
    }

    @Test func withoutALoginShellTheFallbacksStillApply() {
        let parts = ShellPath.merged(login: nil, inherited: "/usr/bin:/bin:/usr/sbin:/sbin", home: "/Users/x").split(separator: ":")
        #expect(parts.contains("/opt/homebrew/bin"))
    }

    @Test func sessionEnvironmentScrubsHostKeysAndSetsPath() {
        let environment = ClaudeCLI.sessionEnvironment(
            ["PATH": "/usr/bin:/bin", "HOME": "/Users/x", "CLAUDECODE": "1"],
            loginPath: "/opt/homebrew/bin:/usr/bin"
        )
        #expect(environment["CLAUDECODE"] == nil)
        #expect(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:/usr/bin:/bin") == true)
    }

    /// Runs this machine's real login shell once.
    @Test func readsThisMachinesLoginShellPath() throws {
        let path = try #require(ShellPath.loginShellPath())
        #expect(path.contains("/usr/bin"))
    }
}

/// A login shell whose startup files leave something running (a daemon,
/// `(sleep 12 &)`) kept the PATH read waiting for that process to close
/// the shared output, past the 4-second limit; every conversation start
/// waited with it.
struct ShellPathHangTests {
    @Test func aBackgroundProcessDoesntHoldUpThePathRead() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "shellpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = folder.appending(path: "fake-shell")
        try """
        #!/bin/sh
        sleep 8 &
        printf '%s%s%s' '\(ShellPath.startMarker)' '/opt/fake/bin:/usr/bin' '\(ShellPath.endMarker)'
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        var path: String?
        let elapsed = ContinuousClock().measure { path = ShellPath.loginShellPath(shell: shell.path) }
        #expect(path == "/opt/fake/bin:/usr/bin")
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }
}
