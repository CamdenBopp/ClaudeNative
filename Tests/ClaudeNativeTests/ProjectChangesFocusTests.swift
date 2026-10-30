import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
import ClaudeNativeCore

/// F6 into the Uncommitted Changes list when it couldn't load says why,
/// rather than doing nothing.
@MainActor
struct ProjectChangesFocusTests {
    final class Token {
        var bump: () -> Void = {}
    }

    struct Host: View {
        let token: Token
        @State var focusToken = 0
        var body: some View {
            // No folder: the list fails with "Choose a folder first."
            ProjectChangesView(folder: nil, refreshToken: 0, focusToken: focusToken) { _ in }
                .onAppear { token.bump = { focusToken += 1 } }
        }
    }

    @Test func f6IntoAListThatFailedSaysWhy() async throws {
        let token = Token()
        let (window, view) = AccessibilityHost.window(hosting: Host(token: token), size: NSSize(width: 500, height: 300))
        defer { window.close() }
        AccessibilityHost.settle(view)
        var heard: [String] = []
        let listener = Announcer.listen { text, _ in if text == "Couldn't read changes. Choose a folder first." { heard.append(text) } }
        defer { Announcer.stopListening(listener) }
        // Wait until the failure shows, however busy the machine is.
        let shown = ContinuousClock.now + .seconds(30)
        while !AccessibilityHost.descendants(of: view).contains(where: { (AccessibilityHost.label($0) ?? AccessibilityHost.value($0) ?? "").contains("Choose a folder first") }),
              ContinuousClock.now < shown {
            try await Task.sleep(for: .milliseconds(50))
        }
        token.bump()
        let deadline = ContinuousClock.now + .seconds(30)
        while heard.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(heard == ["Couldn't read changes. Choose a folder first."])
    }

    /// A load runs up to four git commands (rev-parse, status, hash-object
    /// before the first commit, diff), each allowed GitChanges.commandTimeout.
    /// A fixed 30 s ran out under a loaded full suite, still on "Reading
    /// changes…", while a direct load right after took 10 s: git was slow,
    /// not stuck.
    static let loadDeadline = GitChanges.commandTimeout * 4 + .seconds(5)

    /// The list of changed files is named; VoiceOver called it "table".
    @Test func theChangedFilesListIsNamed() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "changes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path, "-c", "user.email=t@t", "-c", "user.name=t"] + arguments
            try process.run()
            process.waitUntilExit()
        }
        try git("init", "-q")
        try Data("one\n".utf8).write(to: folder.appending(path: "notes.txt"))
        try git("add", ".")
        try git("commit", "-qm", "init")
        try Data("two\n".utf8).write(to: folder.appending(path: "notes.txt"))
        let (window, view) = AccessibilityHost.window(
            hosting: ProjectChangesView(folder: folder, refreshToken: 0, focusToken: 0) { _ in },
            size: NSSize(width: 500, height: 300)
        )
        defer { window.close() }
        let started = ContinuousClock.now
        let deadline = started + Self.loadDeadline
        // Until the list or the failure message shows: the test is about
        // the list's name, so it waits as long as the load itself may run.
        func settled() -> Bool {
            AccessibilityHost.descendants(of: view).contains {
                let label = AccessibilityHost.label($0) ?? ""
                return label.contains("1 file changed") || label.contains("Couldn't Read Changes")
            }
        }
        while !settled(), ContinuousClock.now < deadline {
            AccessibilityHost.settle(view)
            try await Task.sleep(for: .milliseconds(50))
        }
        let tables = AccessibilityHost.descendants(of: view).filter { AccessibilityHost.role($0) == .table || AccessibilityHost.role($0) == .outline }
        // What showed instead, if it never loaded.
        let shown = AccessibilityHost.descendants(of: view).compactMap { AccessibilityHost.label($0) ?? AccessibilityHost.value($0) }.filter { !$0.isEmpty }
        #expect(!tables.isEmpty, "after \(ContinuousClock.now - started): \(shown)")
        #expect(tables.allSatisfy { AccessibilityHost.label($0) == "Changed files" })
    }
}
