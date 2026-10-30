import Foundation
import Testing
@testable import ClaudeNativeCore

/// The probe's two answers, as the 2.1.308 CLI printed them.
struct ThinkingDisplayTests {
    @Test func cliThatKnowsTheFlagListsItsChoices() {
        let output = "error: option '--thinking-display <display>' argument 'claude-native-probe' is invalid. Allowed choices are summarized, omitted, highlights.\n"
        #expect(ThinkingDisplay.probeShowsSupport(output))
    }

    @Test func cliWithoutTheFlagJustPrintsItsVersion() {
        #expect(!ThinkingDisplay.probeShowsSupport("2.1.308 (Claude Code)\n"))
    }

    @Test func anExecutableThatCantRunIsUnsupported() {
        #expect(!ThinkingDisplay.isSupported(by: URL(fileURLWithPath: "/nonexistent/claude")))
    }
}

struct ThinkingDisplayProbeTimeoutTests {
    /// A CLI that never answers must not hold up starting a conversation.
    @Test func aHangingExecutableIsUnsupportedWithinTheTimeout() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "claude")
        try "#!/bin/bash\ntrap '' TERM\nwhile true; do sleep 1; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let started = Date()
        #expect(!ThinkingDisplay.isSupported(by: script))
        #expect(Date().timeIntervalSince(started) < ThinkingDisplay.probeTimeout + 2)
    }
}

struct ThinkingDisplayEnvironmentTests {
    /// A folder with a `claude` script whose interpreter is found only on
    /// PATH, like an npm install needing `node`. The interpreter answers
    /// the probe as a CLI with the flag would. `lingering` leaves a child
    /// holding the output pipe open after it exits.
    static func npmStyleCLI(lingering: Bool = false) throws -> (claude: URL, interpreterFolder: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "npmcli-\(UUID().uuidString)")
        let bin = folder.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let interpreter = bin.appending(path: "fakenode")
        let linger = lingering ? "sleep 20 &\n" : ""
        try "#!/bin/bash\n\(linger)echo \"error: option '--thinking-display <display>' argument 'x' is invalid. Allowed choices are summarized, omitted, highlights.\" >&2\nexit 1\n"
            .write(to: interpreter, atomically: true, encoding: .utf8)
        let claude = folder.appending(path: "claude")
        try "#!/usr/bin/env fakenode\n".write(to: claude, atomically: true, encoding: .utf8)
        for file in [interpreter, claude] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return (claude, bin)
    }

    @Test func probesWithTheEnvironmentTheCLIRunsIn() throws {
        let (claude, bin) = try Self.npmStyleCLI()
        #expect(ThinkingDisplay.isSupported(by: claude, environment: ["PATH": "\(bin.path):/usr/bin:/bin"]))
        let (other, _) = try Self.npmStyleCLI()
        #expect(!ThinkingDisplay.isSupported(by: other, environment: ["PATH": "/usr/bin:/bin"]))
    }

    @Test func aChildHoldingThePipeDoesNotHoldUpTheProbe() throws {
        let (claude, bin) = try Self.npmStyleCLI(lingering: true)
        let started = Date()
        #expect(ThinkingDisplay.isSupported(by: claude, environment: ["PATH": "\(bin.path):/usr/bin:/bin"]))
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
