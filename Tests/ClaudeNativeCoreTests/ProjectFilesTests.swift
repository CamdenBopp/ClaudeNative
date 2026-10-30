import Foundation
import Testing
@testable import ClaudeNativeCore

/// The files panel's tree and filter.
struct ProjectFilesTests {
    static func folder() throws -> TemporaryFolder {
        let folder = try TemporaryFolder()
        let fm = FileManager.default
        for path in ["Sources/App/App.swift", "Sources/App/Readme Notes.md", "README.md", "b.txt", "A.txt", ".hidden", ".git/config", ".build/debug/out.swift", "node_modules/x/index.js"] {
            let url = folder.url.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return folder
    }

    @Test func foldersComeFirstThenNamesAsFinderSortsThem() throws {
        let folder = try Self.folder()
        let names = ProjectFiles.children(of: folder.url).map(\.name)
        #expect(names == ["Sources", "A.txt", "b.txt", "README.md"])
    }

    /// A symbolic link to a folder is a folder in the tree, as in Finder;
    /// it was a file that couldn't be opened.
    @Test func aLinkToAFolderIsAFolder() throws {
        let folder = try Self.folder()
        try FileManager.default.createSymbolicLink(at: folder.url.appending(path: "linked"), withDestinationURL: folder.url.appending(path: "Sources"))
        try FileManager.default.createSymbolicLink(at: folder.url.appending(path: "readme-link.md"), withDestinationURL: folder.url.appending(path: "README.md"))
        let entries = ProjectFiles.children(of: folder.url)
        #expect(entries.first { $0.name == "linked" }?.isFolder == true)
        #expect(entries.first { $0.name == "readme-link.md" }?.isFolder == false)
        #expect(ProjectFiles.children(of: folder.url.appending(path: "linked")).map(\.name) == ["App"])
    }

    @Test func theFilterMatchesPathsAndSkipsToolFolders() throws {
        let folder = try Self.folder()
        let found = ProjectFiles.matches("readme", under: folder.url).map(\.name)
        #expect(found == ["README.md", "Readme Notes.md"])
        #expect(ProjectFiles.matches("swift", under: folder.url).map(\.name) == ["App.swift"])
        #expect(ProjectFiles.matches("app readme", under: folder.url).map(\.name) == ["Readme Notes.md"])
    }

    /// Past the cap, the filter still knows how many matched, so it can
    /// say so; it said "200 files" for thousands.
    /// A project opened through a symbolic link to its folder: the tree
    /// showed its files, but the filter found none, as the walk didn't
    /// follow the link.
    @Test func theFilterSearchesThroughALinkedProjectFolder() throws {
        let folder = try Self.folder()
        let link = FileManager.default.temporaryDirectory.appending(path: "linked-project-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.url)
        defer { try? FileManager.default.removeItem(at: link) }
        let found = ProjectFiles.search("readme", under: link)
        #expect(found.total == 2, "\(found.entries.map(\.url.path))")
    }

    @Test func theFilterCountsEveryMatchPastTheCap() throws {
        let folder = try TemporaryFolder()
        let extra = 25
        for index in 0..<(ProjectFiles.maxMatches + extra) {
            try Data("x".utf8).write(to: folder.url.appending(path: "note\(index).txt"))
        }
        let search = ProjectFiles.search("note", under: folder.url)
        #expect(search.entries.count == ProjectFiles.maxMatches)
        #expect(search.total == ProjectFiles.maxMatches + extra)
        #expect(ProjectFiles.search("nothing here", under: folder.url).total == 0)
    }

    @Test func theFilterSaysHowManyMatchedAndHowManyShow() {
        #expect(ProjectFiles.spokenCount(shown: 1, total: 1) == "1 file.")
        #expect(ProjectFiles.spokenCount(shown: 12, total: 12) == "12 files.")
        #expect(ProjectFiles.spokenCount(shown: 200, total: 5000) == "5000 files, the first 200 shown.")
    }

    @Test func relativePathStopsAtTheFolderBoundary() {
        #expect(ProjectFiles.relativePath(URL(filePath: "/work/app/Sources/Main.swift"), base: "/work/app") == "Sources/Main.swift")
        #expect(ProjectFiles.relativePath(URL(filePath: "/work/app/a.md"), base: "/work/app/") == "a.md")
        #expect(ProjectFiles.relativePath(URL(filePath: "/a.md"), base: "/") == "a.md")
        // A sibling whose name starts like the folder isn't inside it.
        #expect(ProjectFiles.relativePath(URL(filePath: "/work/apple/x.md"), base: "/work/app") == "/work/apple/x.md")
    }
}
