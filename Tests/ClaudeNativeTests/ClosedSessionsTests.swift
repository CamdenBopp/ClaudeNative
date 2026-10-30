import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Reopen Closed Session (Shift-Command-T) passes over a session that was
/// deleted since its window closed; it reopened it from the Trash.
@MainActor
struct ClosedSessionsTests {
    @Test func aDeletedSessionIsPassedOver() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "closed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func session(_ id: String) throws -> SessionHistory.SessionSummary {
            let file = folder.appending(path: "\(id).jsonl")
            try Data().write(to: file)
            return .init(id: id, title: id, lastModified: Date(), fileURL: file)
        }
        let closed = ClosedSessions()
        let kept = try session("kept"), deleted = try session("deleted"), deleting = try session("deleting")
        closed.remember(folder, kept)
        closed.remember(folder, deleted)
        closed.remember(folder, deleting)
        try FileManager.default.removeItem(at: deleted.fileURL)
        let next = closed.takeLastReopenable(isOpen: { _ in false }, isBeingDeleted: { $0 == "deleting" })
        #expect(next?.1.id == "kept")
        #expect(closed.isEmpty)
    }
}
