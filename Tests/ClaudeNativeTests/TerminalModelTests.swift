import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
import ClaudeNativeCore

/// A shell that writes nothing at first (macOS waiting on a folder-access
/// question) gets a note saying why, instead of an empty panel.
@MainActor
struct TerminalModelTests {
    @Test func aSilentShellGetsANote() async throws {
        let terminal = TerminalModel()
        defer { terminal.stop() }
        // Bytes but nothing visible, as zsh's prompt padding once its
        // returns have erased the "%". Held open with cat: under the full
        // suite "sleep 30" in this shell sometimes returned, status 0,
        // within seconds (seen with the shell's own pid; cause unknown).
        terminal.start(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "printf '    \\r \\r'; exec cat"])
        #expect(terminal.waitingNote == nil)
        try await Task.sleep(for: TerminalModel.silenceLimit)
        // Under the full suite's load the note's task can run late.
        for _ in 0..<30 where terminal.waitingNote == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(terminal.waitingNote == TerminalModel.silenceNote, "running \(terminal.isRunning), status \(String(describing: terminal.exitStatus)), shown \(terminal.output.shown.debugDescription)")
    }

    /// Output arriving more often than the pause before announcing (ping,
    /// tail -f, a long build) was never said: each chunk restarted the wait.
    @Test func steadyOutputIsStillAnnounced() async throws {
        let terminal = TerminalModel()
        defer { terminal.stop() }
        var heard: [String] = []
        let listener = Announcer.listen { text, _ in if text.contains("tick") { heard.append(text) } }
        defer { Announcer.stopListening(listener) }
        terminal.isShown = true
        terminal.start(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "while :; do echo tick; sleep 0.3; done"])
        for _ in 0..<80 where heard.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!heard.isEmpty)
    }

    /// Only Control-C could be sent: `cat > notes` couldn't be ended, nor a
    /// job suspended. Control-D ends cat's input here, and the line typed
    /// before it goes first.
    @Test func controlDEndsInput() async throws {
        let terminal = TerminalModel()
        defer { terminal.stop() }
        terminal.start(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "cat; echo cat-ended; exec cat"])
        try await Task.sleep(for: .milliseconds(300))
        terminal.send("hello")
        terminal.sendControl("d", after: "partial")
        try await Task.sleep(for: .milliseconds(200))
        terminal.sendControl("d")
        for _ in 0..<50 where !terminal.output.shown.contains("cat-ended") { try await Task.sleep(for: .milliseconds(100)) }
        #expect(terminal.output.shown.contains("cat-ended"), "\(terminal.output.shown.debugDescription)")
        #expect(terminal.output.shown.contains("partial"))
    }

    /// A password typed for sudo went into a plain field, shown on screen
    /// and spoken. While the program has echo off, the field is secure.
    @Test func aPasswordPromptMakesTheFieldSecure() async throws {
        let terminal = TerminalModel()
        defer { terminal.stop() }
        terminal.start(in: URL(fileURLWithPath: "/"), shell: "/bin/sh",
                       arguments: ["-c", "stty -echo; printf 'Password:'; read secret; stty echo; echo; echo read-it; exec cat"])
        for _ in 0..<50 where !terminal.output.shown.contains("Password:") { try await Task.sleep(for: .milliseconds(100)) }
        for _ in 0..<20 where !terminal.readsSecretly { try await Task.sleep(for: .milliseconds(100)) }
        #expect(terminal.readsSecretly)
        terminal.send("hunter2")
        for _ in 0..<50 where !terminal.output.shown.contains("read-it") { try await Task.sleep(for: .milliseconds(100)) }
        for _ in 0..<20 where terminal.readsSecretly { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!terminal.readsSecretly)
        #expect(!terminal.output.shown.contains("hunter2"))
    }

    /// zsh's line editor turns echo off at its prompt as well; that's not
    /// a password prompt, and the command field must stay plain there.
    @Test func zshsOwnPromptIsNotAPasswordPrompt() async throws {
        let terminal = TerminalModel()
        defer { terminal.stop() }
        terminal.start(in: URL(fileURLWithPath: "/"), shell: "/bin/zsh", arguments: ["-f", "-i"])
        for _ in 0..<50 where !terminal.hasOutput { try await Task.sleep(for: .milliseconds(100)) }
        terminal.send("echo ready")
        for _ in 0..<50 where !terminal.output.shown.contains("ready\n") { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(500))
        terminal.send("")
        try await Task.sleep(for: .milliseconds(500))
        #expect(!terminal.readsSecretly)
    }

    /// Switching folders starts a new shell; output the old one had
    /// already sent landed in the new one's panel.
    @Test func anOldShellsOutputStaysOutOfTheNewOnes() async throws {
        let terminal = TerminalModel()
        defer { terminal.stop() }
        terminal.start(in: URL(fileURLWithPath: "/"), shell: "/usr/bin/yes", arguments: ["OLD-SHELL"])
        // Long enough for output to be on its way, short enough that it's
        // quick to drain.
        try await Task.sleep(for: .milliseconds(20))
        // In one turn, as switching folders does, with old output in flight.
        terminal.start(in: URL(fileURLWithPath: "/tmp"), shell: "/bin/sh", arguments: ["-c", "echo NEW-SHELL; exec cat"])
        try await Task.sleep(for: .milliseconds(800))
        #expect(terminal.output.shown.contains("NEW-SHELL"))
        #expect(!terminal.output.shown.contains("OLD-SHELL"))
        #expect(terminal.isRunning)
    }

    /// A command that floods output doesn't bury the app: each read was
    /// its own task on the main thread, and 300 ms of `yes` left a backlog
    /// that took about 2.5 minutes to clear after the shell had stopped.
    @Test func aFloodOfOutputDoesntBuryTheMainThread() async throws {
        let terminal = TerminalModel()
        defer { terminal.stop() }
        terminal.start(in: URL(fileURLWithPath: "/"), shell: "/usr/bin/yes", arguments: ["FLOOD"])
        try await Task.sleep(for: .milliseconds(300))
        terminal.stop()
        let asked = ContinuousClock.now
        await Task { @MainActor in }.value
        let waited = ContinuousClock.now - asked
        #expect(waited < Self.allowedBacklog, "the main thread was free after \(waited)")
        #expect(terminal.output.shown.contains("FLOOD"))
    }

    /// Alone it measures about 0.15 s; in the full suite other hosted tests
    /// hold the main thread too (it measured 19 s there once). Broken, it
    /// was 138 s (80 s with batching alone), so this still tells them
    /// apart; PendingOutputTests check the mechanism exactly.
    static let allowedBacklog: Duration = .seconds(60)

    @Test func aShellThatPromptsGetsNone() async throws {
        let terminal = TerminalModel()
        defer { terminal.stop() }
        terminal.start(in: URL(fileURLWithPath: "/"), shell: "/bin/sh", arguments: ["-c", "echo ready; sleep 30"])
        try await Task.sleep(for: TerminalModel.silenceLimit + .milliseconds(500))
        #expect(terminal.waitingNote == nil)
        #expect(terminal.output.shown.contains("ready"))
    }
}

/// Reading earlier output while a command still prints: VoiceOver's place
/// in "Terminal output" follows the text view's selection, and every
/// chunk replaced the whole text, which reset it.
@MainActor
struct TerminalOutputViewTests {
    /// Both while the output is longer than the view and while it fits,
    /// where the view keeps itself scrolled to the end as output arrives.
    @Test(arguments: [50, 5])
    func newOutputLeavesTheReadingPlaceAlone(lines: Int) throws {
        let first = (1...lines).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let (window, host) = AccessibilityHost.window(hosting: TerminalOutputView(text: first), size: NSSize(width: 400, height: 300))
        defer { window.close() }
        let textView = try #require(MessageNavigationHostedTests.Hosted.views(NSTextView.self, in: host).first)
        let place = NSRange(location: 7, length: 4)
        textView.setSelectedRange(place)
        host.rootView = TerminalOutputView(text: first + "line 51\n")
        AccessibilityHost.settle(host)
        #expect(textView.string.hasSuffix("line 51\n"))
        #expect(textView.selectedRange() == place)
    }

    /// Past the kept length, each new line drops one from the front, so the
    /// old and new text shared no start and the view replaced all of it:
    /// the selection and VoiceOver's place were lost on every update.
    @Test func droppingOldLinesKeepsTheReadingPlace() throws {
        let lines = (1...50).map { "line \($0)\n" }
        let first = lines.joined()
        let (window, host) = AccessibilityHost.window(hosting: TerminalOutputView(text: first), size: NSSize(width: 400, height: 300))
        defer { window.close() }
        let textView = try #require(MessageNavigationHostedTests.Hosted.views(NSTextView.self, in: host).first)
        let start = (first as NSString).range(of: "line 30").location
        textView.setSelectedRange(NSRange(location: start, length: 7))
        host.rootView = TerminalOutputView(text: lines.dropFirst().joined() + "line 51\n", dropped: lines[0].count)
        AccessibilityHost.settle(host)
        #expect(textView.string.hasPrefix("line 2\n") && textView.string.hasSuffix("line 51\n"))
        #expect((textView.string as NSString).substring(with: textView.selectedRange()) == "line 30")
    }

    /// A line rewritten in place (a progress count) isn't an addition at
    /// the end, so the text is replaced; the place in the earlier lines,
    /// which didn't change, stays.
    @Test func aRewrittenLastLineLeavesTheReadingPlaceAlone() throws {
        let (window, host) = AccessibilityHost.window(hosting: TerminalOutputView(text: "line 1\nline 2\nprogress 50%"), size: NSSize(width: 400, height: 300))
        defer { window.close() }
        let textView = try #require(MessageNavigationHostedTests.Hosted.views(NSTextView.self, in: host).first)
        let place = NSRange(location: 7, length: 4)
        textView.setSelectedRange(place)
        host.rootView = TerminalOutputView(text: "line 1\nline 2\nprogress 100%\n")
        AccessibilityHost.settle(host)
        #expect(textView.string.hasSuffix("100%\n"))
        #expect(textView.selectedRange() == place)
    }
}

/// Output waiting for the main thread: one delivery at a time, and no more
/// kept than the panel could show.
struct PendingOutputTests {
    @Test func onlyOneDeliveryIsPendingAtATime() {
        let pending = PendingOutput()
        #expect(pending.add("a"))
        #expect(!pending.add("b"))
        #expect(!pending.add("c"))
        #expect(pending.take() == "abc")
        #expect(pending.add("d"))
    }

    @Test func aFloodKeepsOnlyItsEndFromALineStart() {
        let pending = PendingOutput()
        let line = "0123456789abcdef\n"
        for _ in 0..<(PendingOutput.keptBytes * 3 / line.utf8.count) { _ = pending.add(line) }
        let kept = pending.take()
        #expect(kept.utf8.count <= PendingOutput.keptBytes * 2)
        #expect(kept.hasPrefix(line))
        #expect(kept.hasSuffix(line))
    }
}

