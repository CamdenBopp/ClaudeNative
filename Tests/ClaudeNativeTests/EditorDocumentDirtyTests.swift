import Foundation
import Testing
@testable import ClaudeNative

/// Undoing back to the text on disk leaves nothing to save, as in TextEdit
/// and Xcode: the status says "Saved" again and Save dims.
@MainActor
struct EditorDocumentDirtyTests {
    @Test func returningToTheSavedTextIsNotAnEdit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dirty-\(UUID().uuidString).swift")
        try "let x = 1\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        #expect(!document.isDirty)
        document.edited("let x = 1\nx")
        #expect(document.isDirty)
        document.edited("let x = 1\n")
        #expect(!document.isDirty)
    }

    /// A file the editor couldn't read as text is never written over: one
    /// typed character and Command-S replaced a whole Latin-1 file with it.
    @Test func aFileThatCouldntBeReadIsNeverSavedOver() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("latin1-\(UUID().uuidString).txt")
        let original = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        #expect(document.loadError != nil)
        document.edited("x")
        document.save()
        #expect(try Data(contentsOf: url) == original)
        document.saveAnyway()
        #expect(try Data(contentsOf: url) == original)
        #expect(document.loadError?.contains("Couldn't save") == true)
    }

    /// Saving a linked file (a symlinked CLAUDE.md) writes the file it
    /// points to; the save replaced the link with a copy and left the
    /// real file as it was.
    @Test func savingThroughALinkWritesTheFileItPointsTo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appendingPathComponent("real.md"), link = folder.appendingPathComponent("CLAUDE.md")
        try "old\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let document = EditorDocument(url: link)
        document.edited("new\n")
        document.save()
        #expect(try String(contentsOf: real, encoding: .utf8) == "new\n")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    /// A file that starts with a UTF-8 byte order mark keeps it.
    @Test func savingKeepsAByteOrderMark() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bom-\(UUID().uuidString).txt")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("old\n".utf8)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        document.edited("new\n")
        document.save()
        #expect(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF]) + Data("new\n".utf8))
    }

    /// Return types a bare newline, so a line added to a Windows-style file
    /// was saved LF among CRLF lines. Saving keeps the file's endings.
    @Test func aCRLFFileStaysCRLF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crlf-\(UUID().uuidString).txt")
        try Data("one\r\ntwo\r\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        document.edited(document.text + "three\n")
        document.save()
        #expect(try Data(contentsOf: url) == Data("one\r\ntwo\r\nthree\r\n".utf8))
        #expect(!document.isDirty)
        // Its own save isn't taken for a change on disk and reloaded.
        let token = document.reloadToken
        document.checkDisk()
        #expect(document.reloadToken == token)
    }

    /// A file with Unix endings is saved as typed.
    @Test func anLFFileStaysLF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lf-\(UUID().uuidString).txt")
        try Data("one\ntwo\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        document.edited(document.text + "three\n")
        document.save()
        #expect(try Data(contentsOf: url) == Data("one\ntwo\nthree\n".utf8))
    }

    /// A locked file (chmod 444) was replaced anyway: the atomic write
    /// swaps in a new file, which the permission doesn't stop.
    @Test func aReadOnlyFileIsNotWrittenOver() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("locked-\(UUID().uuidString).txt")
        try Data("keep\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        let document = EditorDocument(url: url)
        document.edited("changed\n")
        document.save()
        #expect(try Data(contentsOf: url) == Data("keep\n".utf8))
        #expect(document.isDirty)
        #expect(document.loadError?.contains("read-only") == true, "\(document.loadError ?? "nil")")
    }

    /// The atomic save swaps in a new file, so another hard link to it kept
    /// the old text and the two came apart.
    @Test func aHardLinkedFileStaysLinked() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hardlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.txt"), other = folder.appendingPathComponent("b.txt")
        try Data("old\n".utf8).write(to: file)
        try FileManager.default.linkItem(at: file, to: other)
        let document = EditorDocument(url: file)
        document.edited("new\n")
        document.save()
        #expect(try Data(contentsOf: other) == Data("new\n".utf8))
        let links = try FileManager.default.attributesOfItem(atPath: file.path)[.referenceCount] as? Int
        #expect(links == 2)
    }
}
