import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// What the permission sheet is told a file tool will change.
@MainActor
struct DiffLoaderTests {
    /// Writing over a file that exists but isn't UTF-8 text isn't a new
    /// file: it was shown as "new file: 1 line added", hiding that the file
    /// would be replaced. With no diff the sheet asks plainly.
    @Test func overwritingAFileThatIsntTextIsNotANewFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "diffloader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appending(path: "notes.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: existing)
        func write(_ url: URL) -> PermissionRequest {
            PermissionRequest(requestID: "w", toolName: "Write", input: .object([
                "file_path": .string(url.path), "content": .string("hello\n"),
            ]))
        }
        #expect(await DiffLoader.load(request: write(existing)) == nil)
        // A file that really doesn't exist yet is still shown as new.
        let fresh = await DiffLoader.load(request: write(folder.appending(path: "new.txt")))
        #expect(fresh?.isNewFile == true)
    }
}
