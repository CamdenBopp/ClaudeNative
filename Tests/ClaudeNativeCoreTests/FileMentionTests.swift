import Foundation
import Testing
@testable import ClaudeNativeCore

/// The message field's @ file picker: what counts as a mention being typed,
/// which files match, and what choosing one leaves in the draft.
struct FileMentionTests {
    @Test func onlyAMentionStillBeingTypedAtTheEndIsAQuery() {
        #expect(FileMentionSearch.query(in: "@") == "")
        #expect(FileMentionSearch.query(in: "Look at @Read") == "Read")
        #expect(FileMentionSearch.query(in: "Look at\n@src/ma") == "src/ma")
        // Finished: a space or line break after it.
        #expect(FileMentionSearch.query(in: "Look at @README.md ") == nil)
        // Not at a word start: an email address.
        #expect(FileMentionSearch.query(in: "mail me@example") == nil)
        #expect(FileMentionSearch.query(in: "No mention here") == nil)
        #expect(FileMentionSearch.query(in: "") == nil)
    }

    @Test func choosingAFileReplacesTheTypedMention() {
        #expect(FileMentionSearch.completed("Look at @Rea", with: "README.md") == "Look at @README.md ")
        #expect(FileMentionSearch.completed("@", with: "Sources/App.swift") == "@Sources/App.swift ")
        // A path with a space is quoted, which the CLI reads (tested live:
        // Claude's Read tool opened @"sub dir/my notes.txt").
        #expect(FileMentionSearch.completed("See @my", with: "sub dir/my notes.txt") == "See @\"sub dir/my notes.txt\" ")
    }

    @Test func startingAMentionKeepsWhatWasTyped() {
        #expect(FileMentionSearch.starting(in: "") == "@")
        #expect(FileMentionSearch.starting(in: "Look at") == "Look at @")
        #expect(FileMentionSearch.starting(in: "Look at ") == "Look at @")
        #expect(FileMentionSearch.starting(in: "Line\n") == "Line\n@")
        // What it leaves is a mention being typed, so the list opens.
        #expect(FileMentionSearch.query(in: FileMentionSearch.starting(in: "Look at")) == "")
    }

    @Test func droppedFilesAreMentionedAfterWhatWasTyped() {
        let root = URL(filePath: "/work/app")
        let files = [URL(filePath: "/work/app/Sources/Main.swift"), URL(filePath: "/work/app/sub dir/my notes.txt")]
        #expect(FileMentionSearch.mentioning(files, under: root, in: "Compare") == "Compare @Sources/Main.swift @\"sub dir/my notes.txt\" ")
        #expect(FileMentionSearch.mentioning(files.prefix(1).map { $0 }, under: root, in: "") == "@Sources/Main.swift ")
        // Outside the folder, or in one that only starts with its name: the full path.
        #expect(FileMentionSearch.mentioning([URL(filePath: "/work/apple/x.md")], under: root, in: "See ") == "See @/work/apple/x.md ")
        #expect(FileMentionSearch.mentioning([URL(filePath: "/tmp/x.md")], under: nil, in: "") == "@/tmp/x.md ")
        #expect(FileMentionSearch.mentioning([], under: root, in: "Hi") == "Hi")
    }

    @Test func filesWhoseNameStartsWithTheQueryComeFirst() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Sources/AppModel.swift", "Sources/Composer.swift", "docs/model-notes.md", "Model.txt", ".hidden/model.swift"] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        // Name starts with "model" first, then any path containing it;
        // hidden folders are skipped as the Files panel skips them.
        #expect(FileMentionSearch.matches("model", under: root) == ["Model.txt", "docs/model-notes.md", "Sources/AppModel.swift"])
        // An empty query lists the folder's own files.
        #expect(FileMentionSearch.matches("", under: root) == ["Model.txt"])
    }

    @Test func aFileIsSpokenByNameThenFolder() {
        #expect(FileMentionSearch.spoken("Sources/ClaudeNative/Composer.swift") == "Composer.swift, in Sources/ClaudeNative")
        #expect(FileMentionSearch.spoken("README.md") == "README.md")
        #expect(FileMentionSearch.countWording(0) == "No files match.")
        #expect(FileMentionSearch.countWording(1) == "1 file.")
        #expect(FileMentionSearch.countWording(12) == "12 files.")
    }
}
