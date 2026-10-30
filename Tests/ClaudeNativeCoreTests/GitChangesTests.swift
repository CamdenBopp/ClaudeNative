import Foundation
import Testing
@testable import ClaudeNativeCore

/// The Changes pane's data: git's unified diff parsed into the tool-diff
/// types, and `GitChanges.load` against real scratch repositories. The
/// fixtures in Tests/Fixtures/git are real `git diff HEAD` output, made by
/// Tests/Fixtures/git/make_fixtures.sh.
struct GitChangesTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/git")

    static func fixture(_ name: String) throws -> [UnifiedDiff.File] {
        let data = try Data(contentsOf: fixtures.appending(path: name))
        return UnifiedDiff.parseFiles(bytes: [UInt8](data))
    }

    static func file(_ path: String, in files: [UnifiedDiff.File]) throws -> UnifiedDiff.File {
        try #require(files.first { $0.path == path }, "no \(path) in \(files.map(\.path))")
    }

    // MARK: - Parsing git's output

    @Test func parsesEveryFileInARealWorktreeDiff() throws {
        let files = try Self.fixture("worktree.diff")
        #expect(files.map(\.path) == [
            "Sources/App.swift", "Sources/New.swift", "café.txt", "doomed.txt", "logo.png",
            "long.txt", "new name.txt", "nonewline.txt", "run.sh", "windows.txt",
        ])
        #expect(files.allSatisfy { $0.diff.toolName == GitChanges.toolName && !$0.diff.isApproximate })
        #expect(files.flatMap { $0.diff.hunks }.allSatisfy { $0.numbersAreFileLines })
    }

    @Test func modifiedFileHasRealLineNumbers() throws {
        let app = try Self.file("Sources/App.swift", in: Self.fixture("worktree.diff"))
        let diff = app.diff
        #expect(diff.hunks.count == 1)
        let hunk = diff.hunks[0]
        #expect((hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount) == (3, 8, 3, 9))
        #expect(hunk.title == "Change 1 of 1, lines 3 to 11")
        let changed = hunk.lines.filter { $0.kind != .context }
        #expect(changed.map(\.spoken) == [
            "Added, line 6:     let build: Int",
            "Removed, line 9:     print(\"hello\")",
            "Added, line 10:     print(\"hello, world\")",
        ])
        #expect(hunk.lines.first == DiffLine(kind: .context, oldNumber: 3, newNumber: 3, text: "struct App {", ending: .lf))
        #expect(diff.summary == "Changes to Sources/App.swift: 2 lines added, 1 removed")
        #expect(!app.isNew && !app.isDeleted && !app.isRename && !app.isBinary)
    }

    @Test func multipleHunksAreNumbered() throws {
        let long = try Self.file("long.txt", in: Self.fixture("worktree.diff")).diff
        #expect(long.hunks.map(\.title) == ["Change 1 of 2, lines 1 to 6", "Change 2 of 2, lines 24 to 30"])
        let second = long.hunks[1].lines.filter { $0.kind != .context }
        #expect(second.map(\.spoken) == ["Removed, line 27: line 27", "Added, line 27: line twenty-seven"])
        #expect(long.summary == "Changes to long.txt: 2 lines added, 2 removed, in 2 places")
    }

    @Test func newAndDeletedFiles() throws {
        let files = try Self.fixture("worktree.diff")
        let new = try Self.file("Sources/New.swift", in: files)
        #expect(new.isNew && new.oldPath == nil && new.newMode == "100644")
        #expect(new.diff.isNewFile)
        #expect(new.diff.hunks.map(\.title) == ["Change 1 of 1, lines 1 to 2"])
        #expect(new.diff.hunks[0].oldStart == 0)

        let doomed = try Self.file("doomed.txt", in: files)
        #expect(doomed.isDeleted && doomed.newPath == nil && doomed.oldPath == "doomed.txt")
        #expect(doomed.diff.hunks.map(\.title) == ["Change 1 of 1, old lines 1 to 3"])
        #expect(doomed.diff.removedCount == 3)
    }

    @Test func renameWithSpacesInThePath() throws {
        let renamed = try Self.file("new name.txt", in: Self.fixture("worktree.diff"))
        #expect(renamed.isRename)
        #expect(renamed.oldPath == "old name.txt")
        #expect(renamed.similarity == 73)
        #expect(renamed.diff.hunks[0].lines.last?.spoken == "Added, line 4: four")
    }

    @Test func quotedPathsAreDecoded() throws {
        let worktree = try Self.fixture("worktree.diff")
        #expect(try Self.file("café.txt", in: worktree).diff.addedCount == 1)

        let edges = try Self.fixture("edges.diff")
        // The name holds a double quote and a literal backslash-t.
        let odd = try Self.file("quote\"and\\ttab.txt", in: edges)
        #expect(odd.isNew)
        #expect(odd.diff.hunks[0].lines[0].text == "tab\there")

        let pureRename = try Self.file("ünïcode name.txt", in: edges)
        #expect(pureRename.isRename && pureRename.oldPath == "café.txt")
        #expect(pureRename.similarity == 100 && pureRename.diff.hunks.isEmpty)
    }

    @Test func binaryFilesHaveNoHunks() throws {
        let worktree = try Self.fixture("worktree.diff")
        let logo = try Self.file("logo.png", in: worktree)
        #expect(logo.isBinary && logo.diff.hunks.isEmpty && !logo.isNew)

        let edges = try Self.fixture("edges.diff")
        let added = try Self.file("blob.bin", in: edges)
        #expect(added.isBinary && added.isNew)
        let deleted = try Self.file("logo.png", in: edges)
        #expect(deleted.isBinary && deleted.isDeleted)
    }

    @Test func modeOnlyChange() throws {
        let script = try Self.file("run.sh", in: Self.fixture("worktree.diff"))
        #expect(script.oldMode == "100644" && script.newMode == "100755")
        #expect(script.diff.hunks.isEmpty)
        let changed = GitChanges.changedFile(path: "run.sh", status: .modified, staged: false, unstaged: true, parsed: script)
        #expect(changed.spoken == "Modified, run.sh, made executable")
    }

    @Test func noNewlineAtEndOfFile() throws {
        let kept = try Self.file("nonewline.txt", in: Self.fixture("worktree.diff")).diff
        let lines = kept.hunks[0].lines
        #expect(lines.map(\.ending) == [.lf, nil, nil])
        #expect(lines[1].spoken == "Removed, line 2: last, no newline at end of file")
        #expect(kept.oldMissingFinalNewline && kept.newMissingFinalNewline)
        #expect(kept.summary == "Changes to nonewline.txt: 1 line added, 1 removed")

        let added = try Self.file("nonewline.txt", in: Self.fixture("edges.diff")).diff
        #expect(added.oldMissingFinalNewline && !added.newMissingFinalNewline)
        #expect(added.summary == "Changes to nonewline.txt: 1 line added, 1 removed. Adds a newline at end of file")
    }

    @Test func crlfContent() throws {
        let kept = try Self.file("windows.txt", in: Self.fixture("worktree.diff")).diff
        #expect(kept.oldLineEndings == .crlf && kept.newLineEndings == .crlf)
        let lines = kept.hunks[0].lines
        #expect(lines.map(\.text) == ["alpha", "beta", "BETA", "gamma"])
        #expect(lines.allSatisfy { $0.ending == .crlf && !$0.speaksEnding })

        let converted = try Self.file("windows.txt", in: Self.fixture("edges.diff")).diff
        #expect(converted.summary == "Changes to windows.txt: 3 lines added, 3 removed. Line endings change from CRLF to LF")
        #expect(converted.hunks[0].lines.first?.spoken == "Removed, line 1: alpha, CRLF line ending")
        #expect(converted.hunks[0].lines.last?.spoken == "Added, line 3: gamma, LF line ending")
    }

    @Test func insertionAtTheTopOfAFile() throws {
        let long = try Self.file("long.txt", in: Self.fixture("edges.diff")).diff
        #expect(long.hunks.map(\.title) == ["Change 1 of 1, lines 1 to 4"])
        #expect(long.hunks[0].lines[0] == DiffLine(kind: .added, oldNumber: nil, newNumber: 1, text: "line 0", ending: .lf))
        #expect(long.hunks[0].lines[1] == DiffLine(kind: .context, oldNumber: 1, newNumber: 2, text: "line 1", ending: .lf))
    }

    @Test func publicParseReturnsTheFileDiffs() throws {
        let text = try String(contentsOf: Self.fixtures.appending(path: "worktree.diff"), encoding: .utf8)
        #expect(UnifiedDiff.parse(text) == UnifiedDiff.parseFiles(text).map(\.diff))
        #expect(UnifiedDiff.parse(text).count == 10)
    }

    @Test func plainUnifiedDiffAndShortHunkHeaders() {
        // No "diff --git" line, counts left out, a blank context line with
        // its space trimmed, and a timestamp after the name.
        let text = "--- a/x.txt\t2026-01-01\n+++ b/x.txt\t2026-01-02\n@@ -1 +1 @@\n-old\n+new\n@@ -5,3 +5,3 @@\n a\n\n-b\n+c\n"
        let files = UnifiedDiff.parse(text)
        #expect(files.count == 1)
        #expect(files.first?.path == "x.txt")
        #expect(files.first?.hunks.map(\.title) == ["Change 1 of 2, line 1", "Change 2 of 2, lines 5 to 7"])
        #expect(files.first?.hunks.last?.lines.map(\.spoken) == [
            "Unchanged, line 5: a", "Unchanged, line 6: blank line", "Removed, line 7: b", "Added, line 7: c",
        ])
    }

    @Test func truncatedDiffKeepsWhatItRead() {
        let files = UnifiedDiff.parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n a\n-b\n")
        #expect(files.first?.hunks.first?.lines.count == 2)
    }

    @Test func conflictStatusFixture() throws {
        let text = try String(contentsOf: Self.fixtures.appending(path: "conflict.status"), encoding: .utf8)
        let report = StatusReport.parse(Data(text.replacingOccurrences(of: "\n", with: "\0").utf8))
        #expect(report.branch == "main")
        #expect(report.headCommit?.count == 40)
        #expect(report.entries == [StatusReport.Entry(path: "nonewline.txt", kind: .unmerged)])
        let diff = try Self.file("nonewline.txt", in: Self.fixture("conflict.diff"))
        #expect(diff.diff.hunks[0].lines.filter { $0.kind == .added }.map(\.text) == ["<<<<<<< HEAD", "=======", "side", ">>>>>>> side"])
    }

    // MARK: - Spoken summaries

    @Test func spokenSummaries() {
        let files = [
            ChangedFile(path: "a", status: .modified, staged: false, unstaged: true, diff: nil),
            ChangedFile(path: "b", status: .modified, staged: true, unstaged: false, diff: nil),
            ChangedFile(path: "c", status: .added, staged: true, unstaged: false, diff: nil),
        ]
        #expect(GitChanges.spokenSummary(files) == "3 files changed: 2 modified, 1 added")
        #expect(GitChanges.spokenSummary([files[2]]) == "1 file changed: 1 added")
        #expect(GitChanges.spokenSummary([]) == "No uncommitted changes")
        #expect(GitChangeSet.notARepository.spokenSummary == "Not a git repository")
        let binary = ChangedFile(path: "logo.png", status: .modified, staged: false, unstaged: true, isBinary: true, diff: nil)
        #expect(binary.changeSummary == "Binary file")
        #expect(binary.spoken == "Modified, logo.png, binary file")
        let renamed = ChangedFile(path: "b.txt", status: .renamed(from: "a.txt"), staged: true, unstaged: false, diff: nil)
        #expect(renamed.spoken == "Renamed, b.txt, from a.txt, content unchanged")
    }

    // MARK: - Loading from real repositories

    @Test func loadsEveryKindOfChange() async throws {
        let repo = try await ScratchRepo.make()
        defer { repo.remove() }
        try repo.write("Sources/App.swift", "import Foundation\n\nstruct App {\n    let name: String\n}\n")
        try repo.write("old.txt", "one\ntwo\nthree\n")
        try repo.write("gone.txt", "bye\n")
        try repo.write("windows.txt", "alpha\r\nbeta\r\n")
        try repo.write("tail.txt", "first\nlast")
        try repo.write("both.txt", "1\n2\n3\n")
        try repo.write(bytes: [0x89, 0x50, 0x00, 0x01], to: "logo.png")
        try await repo.commitAll()

        try repo.write("Sources/App.swift", "import Foundation\n\nstruct App {\n    let name: String\n    let build: Int\n}\n")
        try await repo.git("mv", "old.txt", "new name.txt")
        try FileManager.default.removeItem(at: repo.url.appending(path: "gone.txt"))
        try repo.write("windows.txt", "alpha\r\nBETA\r\n")
        try repo.write("tail.txt", "first\nfinal")
        try repo.write("both.txt", "1\ntwo\n3\n")
        try await repo.git("add", "both.txt")
        try repo.write("both.txt", "1\ntwo\nthree\n")
        try repo.write(bytes: [0x89, 0x50, 0x00, 0x02], to: "logo.png")
        try repo.write("Sources/New.swift", "brand\nnew\n")
        try await repo.git("add", "Sources/New.swift")
        try repo.write("notes/todo list.md", "- one\n- two\n")
        try repo.write(bytes: [0x00, 0xFF], to: "scratch.bin")

        let result = try await GitChanges.load(in: repo.url)
        guard case .repository(let repository) = result else {
            Issue.record("expected a repository, got \(result)")
            return
        }
        #expect(repository.root.resolvingSymlinksInPath() == repo.url.resolvingSymlinksInPath())
        #expect(repository.branch == "main")
        #expect(repository.hasCommits)
        #expect(repository.files.map(\.spoken) == [
            "Modified, Sources/App.swift, 1 line added",
            "Added, Sources/New.swift, 2 lines added",
            "Modified, both.txt, 2 lines added, 2 removed",
            "Deleted, gone.txt, 1 line removed",
            "Modified, logo.png, binary file",
            "Renamed, new name.txt, from old.txt, content unchanged",
            "Untracked, notes/todo list.md, 2 lines added",
            "Untracked, scratch.bin, binary file",
            "Modified, tail.txt, 1 line added, 1 removed",
            "Modified, windows.txt, 1 line added, 1 removed",
        ])
        #expect(repository.spokenSummary == "10 files changed: 5 modified, 1 added, 1 deleted, 1 renamed, 2 untracked")

        let byPath = Dictionary(uniqueKeysWithValues: repository.files.map { ($0.path, $0) })
        #expect(byPath["both.txt"].map { [$0.staged, $0.unstaged] } == [true, true])
        #expect(byPath["Sources/New.swift"].map { [$0.staged, $0.unstaged] } == [true, false])
        #expect(byPath["Sources/App.swift"].map { [$0.staged, $0.unstaged] } == [false, true])
        #expect(byPath["notes/todo list.md"].map { [$0.staged, $0.unstaged] } == [false, true])
        #expect(byPath["logo.png"]?.diff == nil)
        #expect(byPath["notes/todo list.md"]?.diff?.isNewFile == true)

        // Git's diff is the same diff ToolDiff makes from the two texts.
        let cases: [(String, String, String)] = [
            ("Sources/App.swift", "import Foundation\n\nstruct App {\n    let name: String\n}\n",
             "import Foundation\n\nstruct App {\n    let name: String\n    let build: Int\n}\n"),
            ("windows.txt", "alpha\r\nbeta\r\n", "alpha\r\nBETA\r\n"),
            ("tail.txt", "first\nlast", "first\nfinal"),
            ("both.txt", "1\n2\n3\n", "1\ntwo\nthree\n"),
        ]
        for (path, old, new) in cases {
            let expected = ToolDiff.exact(toolName: GitChanges.toolName, path: path, old: Array(old.utf8), new: Array(new.utf8))
            #expect(byPath[path]?.diff == expected, "\(path)")
        }
        let untracked = ToolDiff.exact(toolName: GitChanges.toolName, path: "notes/todo list.md", old: nil, new: Array("- one\n- two\n".utf8))
        #expect(byPath["notes/todo list.md"]?.diff == untracked)

        // From a subfolder, the whole repository's changes, relative to its top.
        let fromSubfolder = try await GitChanges.load(in: repo.url.appending(path: "Sources"))
        #expect(fromSubfolder.files == repository.files)
    }

    @Test func folderOutsideAnyRepository() async throws {
        let folder = try await ScratchRepo.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await GitChanges.load(in: folder)
        #expect(result == .notARepository)
        #expect(!result.isRepository && result.files.isEmpty)
    }

    @Test func insideTheGitFolderIsNotARepository() async throws {
        let repo = try await ScratchRepo.make()
        defer { repo.remove() }
        #expect(try await GitChanges.load(in: repo.url.appending(path: ".git")) == .notARepository)
    }

    @Test func missingFolderThrows() async {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        await #expect(throws: GitChangesError.folderMissing(missing.path)) {
            try await GitChanges.load(in: missing)
        }
    }

    @Test func repositoryWithNoCommits() async throws {
        let repo = try await ScratchRepo.make()
        defer { repo.remove() }
        try repo.write("staged.txt", "a\nb\n")
        try await repo.git("add", "staged.txt")
        try repo.write("staged.txt", "a\nb\nc\n")
        try repo.write("loose.txt", "x\n")

        let result = try await GitChanges.load(in: repo.url)
        guard case .repository(let repository) = result else {
            Issue.record("expected a repository, got \(result)")
            return
        }
        #expect(repository.headCommit == nil && !repository.hasCommits)
        #expect(repository.branch == "main")
        #expect(repository.files.map(\.spoken) == [
            "Untracked, loose.txt, 1 line added",
            "Added, staged.txt, 3 lines added",
        ])
        #expect(repository.files.last.map { [$0.staged, $0.unstaged] } == [true, true])
        #expect(repository.files.last?.diff?.isNewFile == true)
    }

    @Test func cleanRepository() async throws {
        let repo = try await ScratchRepo.make()
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")
        try await repo.commitAll()
        let result = try await GitChanges.load(in: repo.url)
        #expect(result.isRepository && result.files.isEmpty)
        #expect(result.spokenSummary == "No uncommitted changes")
    }

    @Test func mergeConflict() async throws {
        let repo = try await ScratchRepo.make()
        defer { repo.remove() }
        try repo.write("f.txt", "first\n")
        try await repo.commitAll()
        try await repo.git("checkout", "-q", "-b", "side")
        try repo.write("f.txt", "side\n")
        try await repo.commitAll()
        try await repo.git("checkout", "-q", "main")
        try repo.write("f.txt", "main\n")
        try await repo.commitAll()
        _ = try await repo.runner.run(ScratchRepo.identity + ["merge", "-q", "side"], in: repo.url)

        let files = try await GitChanges.load(in: repo.url).files
        #expect(files.map(\.status) == [.conflicted])
        #expect(files.first?.spoken == "Conflicted, f.txt, 4 lines added")
    }

    @Test func detachedHeadHasNoBranch() async throws {
        let repo = try await ScratchRepo.make()
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")
        try await repo.commitAll()
        try await repo.git("checkout", "-q", "--detach")
        guard case .repository(let repository) = try await GitChanges.load(in: repo.url) else {
            Issue.record("expected a repository")
            return
        }
        #expect(repository.branch == nil && repository.headCommit != nil)
    }

    @Test func hungGitTimesOut() async throws {
        let folder = try await ScratchRepo.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appending(path: "git")
        try "#!/bin/sh\nexec sleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let started = ContinuousClock.now
        await #expect(throws: GitChangesError.timedOut(command: "rev-parse")) {
            try await GitChanges.load(in: folder, git: fake, timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}

/// A throwaway repository in a `mktemp -d` folder, driven by /usr/bin/git
/// with the same scrubbed environment the app uses.
struct ScratchRepo {
    let url: URL
    let runner = GitRunner(git: GitChanges.gitURL, timeout: .seconds(15))

    /// Commits made here never sign, run hooks or need the user's identity.
    static let identity = [
        "-c", "user.name=Scratch", "-c", "user.email=scratch@example.com",
        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "core.autocrlf=false",
    ]

    static func makeFolder() async throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mktemp")
        process.arguments = ["-d", "-t", "gitchanges"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !path.isEmpty else { throw ScratchError(message: "mktemp failed") }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func make() async throws -> ScratchRepo {
        let repo = ScratchRepo(url: try await makeFolder())
        try await repo.git("init", "-q", "-b", "main")
        return repo
    }

    struct ScratchError: Error { let message: String }

    @discardableResult
    func git(_ arguments: String...) async throws -> String {
        let output = try await runner.run(Self.identity + arguments, in: url)
        guard output.status == 0 else {
            throw ScratchError(message: "git \(arguments.joined(separator: " ")): \(output.errorText)")
        }
        return output.outputText
    }

    func commitAll() async throws {
        try await git("add", "-A")
        try await git("commit", "-q", "-m", "commit")
    }

    func write(_ path: String, _ text: String) throws {
        try write(bytes: Array(text.utf8), to: path)
    }

    func write(bytes: [UInt8], to path: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: file)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The toolbar's "+12 −3": lines added and removed in tracked files.
struct ChangeCountsTests {
    static func diff(adding added: Int, removing removed: Int) throws -> FileDiff {
        let lines = (0..<removed).map { "-old \($0)" } + (0..<added).map { "+new \($0)" }
        let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,\(removed) +1,\(added) @@\n" + lines.joined(separator: "\n") + "\n"
        return try #require(UnifiedDiff.parse(text).first)
    }

    @Test func countsTrackedFilesLikeGitShortstat() throws {
        let repository = GitChangeSet.Repository(root: URL(fileURLWithPath: "/r"), branch: "main", headCommit: "abc", files: [
            ChangedFile(path: "a", status: .modified, staged: false, unstaged: true, diff: try Self.diff(adding: 10, removing: 3)),
            ChangedFile(path: "b", status: .added, staged: true, unstaged: false, diff: try Self.diff(adding: 2, removing: 0)),
            // Untracked build output would swamp the count.
            ChangedFile(path: "big.bin", status: .untracked, staged: false, unstaged: false, diff: try Self.diff(adding: 5000, removing: 0)),
        ])
        let counts = try #require(ChangeCounts(.repository(repository)))
        #expect(counts == ChangeCounts(added: 12, removed: 3))
        #expect(counts.title == "+12 \u{2212}3")
        #expect(counts.spoken == "Uncommitted changes, 12 lines added, 3 removed")
        #expect(ChangeCounts(.notARepository) == nil)
    }
}
