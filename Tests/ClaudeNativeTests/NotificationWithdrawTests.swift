import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// A permission notification left in Notification Center after it was
/// answered still says Claude is waiting. It's withdrawn once its request
/// is answered or dropped.
@MainActor
@Suite(.serialized)
struct NotificationWithdrawTests {
    @Test func answeredPermissionsAreWithdrawn() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(cliExecutable: try PermissionAnswerTests.fake(in: folder))
        defer { model.close(appIsQuitting: true) }
        var posted: [String] = []
        var withdrawn: [String] = []
        model.postNotification = { id, _, _ in posted.append(id) }
        model.withdrawNotifications = { withdrawn += $0 }
        model.start(in: folder)
        for _ in 0..<200 where !model.isReady { try await Task.sleep(for: .milliseconds(20)) }
        model.send("Clean up.")
        for _ in 0..<200 where model.permissions.waiting.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let first = model.permissionNotificationID("first"), second = model.permissionNotificationID("second")
        #expect(posted == [first, second])
        model.answerPermission(allow: true, for: "first")
        #expect(withdrawn == [first])
        // Closing the window drops the one still waiting: its notification
        // goes too.
        model.close(appIsQuitting: true)
        #expect(withdrawn == [first, second])
    }
}
