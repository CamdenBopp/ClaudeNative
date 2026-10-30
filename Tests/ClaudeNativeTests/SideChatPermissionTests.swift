import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// The side chat has no sheet: its prompts have nowhere to show. In Plan
/// mode the CLI still asks before a non-read-only command, AskUserQuestion
/// and ExitPlanMode, so the request sat unanswered, the CLI waited for
/// ever and the side chat's field stayed locked. It's declined at once.
@MainActor
@Suite(.serialized)
struct SideChatPermissionTests {
    @Test func aSideChatDeclinesWhatItCantShow() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "side-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chat = SidePanel.makeSideChat(cliExecutable: try PermissionAnswerTests.fake(in: folder))
        defer { chat.close(appIsQuitting: true) }
        var posted = 0
        chat.postNotification = { _, _, _ in posted += 1 }
        chat.start(in: folder)
        for _ in 0..<200 where !chat.isReady { try await Task.sleep(for: .milliseconds(20)) }
        chat.send("Clean up.")
        let answers = folder.appending(path: "answers")
        for _ in 0..<200 where ((try? String(contentsOf: answers, encoding: .utf8)) ?? "").split(separator: "\n").count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(((try? String(contentsOf: answers, encoding: .utf8)) ?? "").split(separator: "\n") == ["first", "second"])
        #expect(chat.pendingPermission == nil)
        #expect(posted == 0)
    }
}
