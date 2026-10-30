import Foundation

/// One file with uncommitted changes, compared with the last commit (or with
/// nothing, in a repository that has no commits yet).
public struct ChangedFile: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable, Hashable {
        case modified
        case added
        case deleted
        case renamed(from: String)
        case untracked
        case conflicted

        /// "Modified", "Renamed" and so on, for the start of a spoken line.
        public var label: String {
            switch self {
            case .modified: "Modified"
            case .added: "Added"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .untracked: "Untracked"
            case .conflicted: "Conflicted"
            }
        }
    }

    /// Relative to the repository's top folder, with "/" between folders.
    public let path: String
    public let status: Status
    /// True when some or all of the change is staged in the index.
    public let staged: Bool
    /// True when some or all of the change is only in the working tree
    /// (always true for untracked and conflicted files).
    public let unstaged: Bool
    /// Git treats the file as binary, so the diff has no lines.
    public let isBinary: Bool
    /// An untracked file too big to read into a diff (see
    /// `GitChanges.untrackedSizeLimit`).
    public let isTooLarge: Bool
    /// File modes ("100644", "100755", "120000") when the change sets or
    /// alters them; nil when git doesn't report one.
    public let oldMode: String?
    public let newMode: String?
    /// The lines that changed. nil when git reports no text diff (a binary
    /// or oversized file, or a conflict git can't show).
    public let diff: FileDiff?

    public init(path: String, status: Status, staged: Bool, unstaged: Bool, isBinary: Bool = false, isTooLarge: Bool = false, oldMode: String? = nil, newMode: String? = nil, diff: FileDiff?) {
        self.path = path
        self.status = status
        self.staged = staged
        self.unstaged = unstaged
        self.isBinary = isBinary
        self.isTooLarge = isTooLarge
        self.oldMode = oldMode
        self.newMode = newMode
        self.diff = diff
    }

    /// Unique within a change set: a path can show up twice when it was
    /// deleted from the index and a new untracked file took its place.
    public var id: String { status == .untracked ? "?" + path : path }

    public var addedCount: Int { diff?.addedCount ?? 0 }
    public var removedCount: Int { diff?.removedCount ?? 0 }

    /// "4 lines added, 1 removed", "Binary file", or what else changed.
    public var changeSummary: String {
        if isBinary { return "Binary file" }
        if isTooLarge { return "Too large to show" }
        var parts: [String] = []
        if addedCount + removedCount > 0 {
            parts.append(FileDiff.counts(added: addedCount, removed: removedCount))
        }
        if let modeChange { parts.append(modeChange) }
        if parts.isEmpty {
            if case .renamed = status { return "Content unchanged" }
            return "No changes"
        }
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// "Modified, Sources/App.swift, 4 lines added, 1 removed".
    public var spoken: String {
        var result = "\(status.label), \(path)"
        if case .renamed(let from) = status { result += ", from \(from)" }
        let summary = changeSummary
        return result + ", " + summary.prefix(1).lowercased() + summary.dropFirst()
    }

    /// "made executable" when only the executable bit changed; otherwise
    /// the raw modes. nil for new and deleted files, whose mode is just
    /// the file's own.
    var modeChange: String? {
        guard let oldMode, let newMode, oldMode != newMode else { return nil }
        switch (oldMode, newMode) {
        case ("100644", "100755"): return "made executable"
        case ("100755", "100644"): return "no longer executable"
        default: return "mode changed from \(oldMode) to \(newMode)"
        }
    }
}

/// The uncommitted changes in a folder.
public enum GitChangeSet: Sendable, Equatable {
    /// The folder isn't inside a git working tree.
    case notARepository
    case repository(Repository)

    public struct Repository: Sendable, Equatable {
        /// The working tree's top folder; `ChangedFile.path` is relative to it.
        public let root: URL
        /// The checked-out branch, or nil when HEAD is detached.
        public let branch: String?
        /// HEAD's commit id, or nil when the repository has no commits yet.
        public let headCommit: String?
        /// Sorted by path.
        public let files: [ChangedFile]

        public init(root: URL, branch: String?, headCommit: String?, files: [ChangedFile]) {
            self.root = root
            self.branch = branch
            self.headCommit = headCommit
            self.files = files
        }

        public var hasCommits: Bool { headCommit != nil }

        /// "3 files changed: 2 modified, 1 added", or "No uncommitted changes".
        public var spokenSummary: String { GitChanges.spokenSummary(files) }
    }

    public var isRepository: Bool {
        if case .repository = self { return true }
        return false
    }

    /// Empty when not a repository.
    public var files: [ChangedFile] {
        if case .repository(let repository) = self { return repository.files }
        return []
    }

    public var spokenSummary: String {
        switch self {
        case .notARepository: "Not a git repository"
        case .repository(let repository): repository.spokenSummary
        }
    }
}

public enum GitChangesError: Error, Equatable, LocalizedError {
    case folderMissing(String)
    case launchFailed(String)
    case timedOut(command: String)
    case failed(command: String, status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .folderMissing(let path): "The folder \(path) doesn't exist."
        case .launchFailed(let reason): "Git couldn't start: \(reason)"
        case .timedOut(let command): "git \(command) took too long and was stopped."
        case .failed(let command, let status, let message):
            message.isEmpty ? "git \(command) failed with status \(status)." : "git \(command) failed: \(message)"
        }
    }
}

/// Reads a folder's uncommitted changes with git, as the diff types the
/// tool rows use, for a Changes pane.
public enum GitChanges {
    public static let gitURL = URL(fileURLWithPath: "/usr/bin/git")
    /// How long one git command may run.
    public static let commandTimeout: Duration = .seconds(15)
    /// Git's own binary check: a NUL byte in the first 8000 bytes.
    static let binarySniffLength = 8000
    /// Untracked files bigger than this get no diff.
    public static let untrackedSizeLimit = 8 * 1024 * 1024
    /// The toolName on every FileDiff this makes, which its summary starts
    /// with: "Changes to demo.swift: 1 line added".
    public static let toolName = "Changes to"

    /// Diff flags that keep the output parseable whatever the user's git
    /// config says (colour, external diff tools, prefixes, relative paths).
    static let diffFlags = [
        "--no-color", "--no-ext-diff", "--no-textconv", "-M",
        "--src-prefix=a/", "--dst-prefix=b/", "--no-relative",
    ]

    /// Staged and unstaged changes against HEAD (`git diff HEAD`), plus
    /// untracked files shown as all added. A folder outside any working
    /// tree gives `.notARepository`; a missing folder or a git failure
    /// throws.
    public static func load(in folder: URL) async throws -> GitChangeSet {
        try await load(in: folder, git: gitURL, timeout: commandTimeout)
    }

    static func load(in folder: URL, git: URL, timeout: Duration) async throws -> GitChangeSet {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitChangesError.folderMissing(folder.path)
        }
        let runner = GitRunner(git: git, timeout: timeout)

        let topLevel = try await runner.run(["rev-parse", "--show-toplevel"], in: folder)
        if topLevel.status != 0 {
            let message = topLevel.errorText
            if message.contains("not a git repository") || message.contains("must be run in a work tree") {
                return .notARepository
            }
            throw GitChangesError.failed(command: "rev-parse", status: topLevel.status, message: message)
        }
        let rootPath = topLevel.outputText.trimmingCharacters(in: .newlines)
        guard !rootPath.isEmpty else { return .notARepository }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)

        let statusResult = try await runner.check(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--find-renames"], in: root)
        let status = StatusReport.parse(statusResult.stdout)

        // Against HEAD, or against the empty tree before the first commit.
        let base: String
        if status.headCommit != nil {
            base = "HEAD"
        } else {
            let emptyTree = try await runner.check(["hash-object", "-t", "tree", "/dev/null"], in: root)
            base = emptyTree.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let diffResult = try await runner.check(["diff", base] + diffFlags + ["--"], in: root)
        let parsed = UnifiedDiff.parseFiles(bytes: [UInt8](diffResult.stdout))

        let files = merge(status: status.entries, diffs: parsed, root: root)
        return .repository(GitChangeSet.Repository(root: root, branch: status.branch, headCommit: status.headCommit, files: files))
    }

    // MARK: - Combining status and diff

    static func merge(status entries: [StatusReport.Entry], diffs: [UnifiedDiff.File], root: URL) -> [ChangedFile] {
        var diffByPath: [String: UnifiedDiff.File] = [:]
        for file in diffs { diffByPath[file.path] = file }
        var result: [ChangedFile] = []
        var renameSources: Set<String> = []

        for entry in entries {
            switch entry.kind {
            case .untracked:
                result.append(untracked(path: entry.path, root: root))
            case .unmerged:
                let diff = diffByPath.removeValue(forKey: entry.path)
                result.append(changedFile(path: entry.path, status: .conflicted, staged: false, unstaged: true, parsed: diff))
            case .ordinary(let x, let y), .renamed(let x, let y, _):
                let diff = diffByPath.removeValue(forKey: entry.path)
                // Added to the index, then deleted from disk: nothing
                // differs from HEAD.
                if x == "A", y == "D", diff == nil { continue }
                var status: ChangedFile.Status
                if case .renamed(_, _, let from) = entry.kind {
                    status = x == "C" ? .added : .renamed(from: from)
                } else if x == "A" {
                    status = .added
                } else if x == "D" || y == "D" {
                    status = .deleted
                } else {
                    status = .modified
                }
                // The diff can pair a rename that status saw as an add.
                if status == .added, let diff, diff.isRename, let from = diff.oldPath {
                    status = .renamed(from: from)
                }
                if case .renamed(let from) = status { renameSources.insert(from) }
                result.append(changedFile(path: entry.path, status: status, staged: x != ".", unstaged: y != ".", parsed: diff))
            }
        }
        // Whatever the diff showed that status didn't list.
        for file in diffByPath.values where !(file.isDeleted && renameSources.contains(file.path)) {
            let status: ChangedFile.Status = if file.isRename, let from = file.oldPath {
                .renamed(from: from)
            } else if file.isNew {
                .added
            } else if file.isDeleted {
                .deleted
            } else {
                .modified
            }
            if case .renamed(let from) = status { renameSources.insert(from) }
            result.append(changedFile(path: file.path, status: status, staged: false, unstaged: true, parsed: file))
        }
        // A rename the diff paired replaces status's separate delete.
        result.removeAll { $0.status == .deleted && renameSources.contains($0.path) && $0.diff == nil }
        return result.sorted { ($0.path, $0.id) < ($1.path, $1.id) }
    }

    static func changedFile(path: String, status: ChangedFile.Status, staged: Bool, unstaged: Bool, parsed: UnifiedDiff.File?) -> ChangedFile {
        ChangedFile(path: path, status: status, staged: staged, unstaged: unstaged,
                    isBinary: parsed?.isBinary ?? false,
                    oldMode: parsed?.oldMode, newMode: parsed?.newMode,
                    diff: parsed.flatMap { $0.isBinary ? nil : $0.diff })
    }

    /// An untracked file as all added lines, read from disk.
    static func untracked(path: String, root: URL) -> ChangedFile {
        let url = root.appending(path: path, directoryHint: .notDirectory)
        func file(binary: Bool = false, tooLarge: Bool = false, diff: FileDiff? = nil) -> ChangedFile {
            ChangedFile(path: path, status: .untracked, staged: false, unstaged: true,
                        isBinary: binary, isTooLarge: tooLarge, diff: diff)
        }
        let manager = FileManager.default
        let attributes = try? manager.attributesOfItem(atPath: url.path)
        // Git stores a symlink as its target path.
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            guard let target = try? manager.destinationOfSymbolicLink(atPath: url.path) else { return file() }
            return file(diff: ToolDiff.exact(toolName: toolName, path: path, old: nil, new: Array(target.utf8)))
        }
        if let size = attributes?[.size] as? NSNumber, size.intValue > untrackedSizeLimit {
            return file(binary: isBinary(prefixOf: url), tooLarge: true)
        }
        guard let data = try? Data(contentsOf: url) else { return file() }
        let bytes = [UInt8](data)
        if bytes.prefix(binarySniffLength).contains(0) { return file(binary: true) }
        return file(diff: ToolDiff.exact(toolName: toolName, path: path, old: nil, new: bytes))
    }

    static func isBinary(prefixOf url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: binarySniffLength)) ?? Data()
        return head.contains(0)
    }

    // MARK: - Speech

    /// "3 files changed: 2 modified, 1 added".
    public static func spokenSummary(_ files: [ChangedFile]) -> String {
        guard !files.isEmpty else { return "No uncommitted changes" }
        let order: [(String, (ChangedFile.Status) -> Bool)] = [
            ("modified", { $0 == .modified }),
            ("added", { $0 == .added }),
            ("deleted", { $0 == .deleted }),
            ("renamed", { if case .renamed = $0 { true } else { false } }),
            ("untracked", { $0 == .untracked }),
            ("conflicted", { $0 == .conflicted }),
        ]
        let parts = order.compactMap { name, matches -> String? in
            let count = files.count { matches($0.status) }
            return count > 0 ? "\(count) \(name)" : nil
        }
        let subject = files.count == 1 ? "1 file changed" : "\(files.count) files changed"
        return subject + ": " + parts.joined(separator: ", ")
    }
}

// MARK: - git status

/// `git status --porcelain=v2 -z --branch` output.
struct StatusReport: Equatable {
    struct Entry: Equatable {
        enum Kind: Equatable {
            /// X is the index's status and Y the working tree's, "." when
            /// unchanged.
            case ordinary(x: Character, y: Character)
            case renamed(x: Character, y: Character, from: String)
            case unmerged
            case untracked
        }

        let path: String
        let kind: Kind
    }

    var branch: String?
    var headCommit: String?
    var entries: [Entry] = []

    static func parse(_ data: Data) -> StatusReport {
        var report = StatusReport()
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard let type = field.first else { continue }
            switch type {
            case "#":
                let parts = field.split(separator: " ", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let value = String(parts[2])
                switch parts[1] {
                case "branch.oid": report.headCommit = value == "(initial)" ? nil : value
                case "branch.head": report.branch = value == "(detached)" ? nil : value
                default: break
                }
            case "1":
                let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9, let (x, y) = codes(parts[1]) else { continue }
                report.entries.append(Entry(path: String(parts[8]), kind: .ordinary(x: x, y: y)))
            case "2":
                // The original path is the next NUL-separated field.
                let parts = field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10, let (x, y) = codes(parts[1]), index < fields.count else { continue }
                let from = fields[index]
                index += 1
                report.entries.append(Entry(path: String(parts[9]), kind: .renamed(x: x, y: y, from: from)))
            case "u":
                let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                report.entries.append(Entry(path: String(parts[10]), kind: .unmerged))
            case "?":
                report.entries.append(Entry(path: String(field.dropFirst(2)), kind: .untracked))
            default:
                break
            }
        }
        return report
    }

    private static func codes(_ xy: Substring) -> (Character, Character)? {
        guard xy.count == 2, let x = xy.first, let y = xy.last else { return nil }
        return (x, y)
    }
}

// MARK: - Running git

struct GitRunner {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data

        var outputText: String { String(decoding: stdout, as: UTF8.self) }
        var errorText: String {
            String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    let git: URL
    let timeout: Duration

    /// The app's scrubbed environment without any GIT_ variables (a stray
    /// GIT_DIR would point every command at another repository), in the C
    /// locale so error messages are the English ones checked for.
    static func environment() -> [String: String] {
        var environment = ClaudeCLI.childEnvironment(ProcessInfo.processInfo.environment)
            .filter { !$0.key.hasPrefix("GIT_") }
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }

    /// Runs git and throws unless it exits 0.
    func check(_ arguments: [String], in folder: URL) async throws -> Output {
        let output = try await run(arguments, in: folder)
        guard output.status == 0 else {
            throw GitChangesError.failed(command: arguments.first ?? "", status: output.status, message: output.errorText)
        }
        return output
    }

    /// Runs `git -C folder <arguments>` without a shell and returns how it
    /// exited. Throws only if it can't start, times out or is cancelled.
    func run(_ arguments: [String], in folder: URL) async throws -> Output {
        let process = Process()
        process.executableURL = git
        process.arguments = ["--no-optional-locks", "-C", folder.path] + arguments
        process.environment = Self.environment()
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        let (exits, exitSink) = AsyncStream<Int32>.makeStream()
        let exited = ExitFlag()
        process.terminationHandler = { exited.set(); exitSink.yield($0.terminationStatus); exitSink.finish() }
        do {
            try process.run()
        } catch {
            throw GitChangesError.launchFailed(error.localizedDescription)
        }
        // Drain both pipes at once so a full pipe can't stall git.
        async let stdout = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        async let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        let timeout = self.timeout
        let pid = process.processIdentifier
        // Only while git still runs: once it has exited and been reaped its
        // id can be another process's, and a cancelled refresh killed one
        // (a terminal panel's shell, in the test suite).
        let stopGit: @Sendable () -> Void = { if !exited.isSet { kill(pid, SIGTERM) } }
        let timer = Task { () -> Bool in
            do { try await Task.sleep(for: timeout) } catch { return false }
            stopGit()
            return true
        }
        let status = await withTaskCancellationHandler {
            var status: Int32 = -1
            for await code in exits { status = code }
            return status
        } onCancel: {
            stopGit()
        }
        timer.cancel()
        let timedOut = await timer.value
        let result = Output(status: status, stdout: await stdout, stderr: await stderr)
        if timedOut { throw GitChangesError.timedOut(command: arguments.first ?? "") }
        try Task.checkCancellation()
        return result
    }
}

// MARK: - Unified diff parsing

/// Reads git's unified diff output (`git diff --no-color --no-ext-diff -M`)
/// into the same diff types the file tools use.
public enum UnifiedDiff {
    /// One file's section of the diff, with what git said about it beyond
    /// the lines.
    public struct File: Sendable, Equatable {
        /// nil for a new file.
        public let oldPath: String?
        /// nil for a deleted file.
        public let newPath: String?
        public let isNew: Bool
        public let isDeleted: Bool
        public let isRename: Bool
        public let isBinary: Bool
        public let oldMode: String?
        public let newMode: String?
        /// "similarity index" for a rename or copy, as a percentage.
        public let similarity: Int?
        /// Binary files have no hunks.
        public let diff: FileDiff

        /// The new path, or the old one for a deleted file.
        public var path: String { newPath ?? oldPath ?? "" }
    }

    public static func parse(_ text: String) -> [FileDiff] {
        parseFiles(text).map(\.diff)
    }

    public static func parseFiles(_ text: String) -> [File] {
        parseFiles(bytes: Array(text.utf8))
    }

    static func parseFiles(bytes: [UInt8]) -> [File] {
        var lines = bytes.split(separator: newline, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var files: [File] = []
        var current: Builder?
        var index = 0

        func finish() {
            if let current { files.append(current.build()) }
            current = nil
        }

        while index < lines.count {
            let line = lines[index]
            if line.starts(with: Self.gitHeader) {
                finish()
                var builder = Builder()
                (builder.gitOld, builder.gitNew) = gitHeaderPaths(line.dropFirst(gitHeader.count))
                current = builder
                index += 1
                continue
            }
            if line.starts(with: Self.combinedHeader) || line.starts(with: Self.ccHeader) {
                // A combined (merge) diff: keep the file, skip its hunks.
                finish()
                var builder = Builder()
                let name = line.starts(with: ccHeader) ? line.dropFirst(ccHeader.count) : line.dropFirst(combinedHeader.count)
                builder.gitNew = unquote(name)
                builder.isCombined = true
                current = builder
                index += 1
                continue
            }
            if line.starts(with: Self.oldFileHeader), index + 1 < lines.count, lines[index + 1].starts(with: Self.newFileHeader) {
                // A plain unified diff has no "diff --git" line to start a file.
                if current == nil || current?.hasFileHeaders == true || current?.hunks.isEmpty == false {
                    finish()
                    current = Builder()
                }
                current?.setFileHeaders(old: line.dropFirst(oldFileHeader.count), new: lines[index + 1].dropFirst(newFileHeader.count))
                index += 2
                continue
            }
            if line.starts(with: Self.hunkHeader), current != nil, current?.isCombined == false, let header = HunkHeader(line) {
                index += 1
                let hunk = readHunk(header, lines: lines, index: &index)
                current?.hunks.append(hunk)
                continue
            }
            current?.readExtendedHeader(line)
            index += 1
        }
        finish()
        return files
    }

    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let gitHeader = Array("diff --git ".utf8)
    static let ccHeader = Array("diff --cc ".utf8)
    static let combinedHeader = Array("diff --combined ".utf8)
    static let oldFileHeader = Array("--- ".utf8)
    static let newFileHeader = Array("+++ ".utf8)
    static let hunkHeader = Array("@@ ".utf8)

    // MARK: Hunks

    struct HunkHeader {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int

        /// "@@ -3,8 +3,9 @@ section"; a missing count means 1.
        init?(_ line: ArraySlice<UInt8>) {
            let text = String(decoding: line, as: UTF8.self)
            let parts = text.split(separator: " ")
            guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@",
                  parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
                  let old = Self.range(parts[1].dropFirst()),
                  let new = Self.range(parts[2].dropFirst()) else { return nil }
            (oldStart, oldCount) = old
            (newStart, newCount) = new
        }

        static func range(_ text: Substring) -> (Int, Int)? {
            let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
            guard let start = pieces.first.flatMap({ Int($0) }), start >= 0 else { return nil }
            if pieces.count == 1 { return (start, 1) }
            guard pieces.count == 2, let count = Int(pieces[1]), count >= 0 else { return nil }
            return (start, count)
        }
    }

    struct LineDraft {
        let kind: DiffLine.Kind
        let oldNumber: Int?
        let newNumber: Int?
        /// The line without its "\n", so still with any "\r".
        let bytes: ArraySlice<UInt8>
        var hasNewline = true

        var ending: LineEnding? {
            guard hasNewline else { return nil }
            return bytes.last == UnifiedDiff.carriageReturn ? .crlf : .lf
        }

        var text: String {
            String(decoding: ending == .crlf ? bytes.dropLast() : bytes, as: UTF8.self)
        }
    }

    struct HunkDraft {
        let header: HunkHeader
        var lines: [LineDraft]
    }

    /// Reads hunk lines until the header's counts are used up, along with
    /// any "\ No newline at end of file" markers.
    static func readHunk(_ header: HunkHeader, lines: [ArraySlice<UInt8>], index: inout Int) -> HunkDraft {
        var hunk = HunkDraft(header: header, lines: [])
        var oldLeft = header.oldCount
        var newLeft = header.newCount
        var oldNumber = header.oldStart
        var newNumber = header.newStart
        func markNoNewline() {
            if !hunk.lines.isEmpty { hunk.lines[hunk.lines.count - 1].hasNewline = false }
        }
        while index < lines.count, oldLeft > 0 || newLeft > 0 {
            let line = lines[index]
            switch line.first {
            case UInt8(ascii: "\\"):
                markNoNewline()
            case UInt8(ascii: "-") where oldLeft > 0:
                hunk.lines.append(LineDraft(kind: .removed, oldNumber: oldNumber, newNumber: nil, bytes: line.dropFirst()))
                oldNumber += 1
                oldLeft -= 1
            case UInt8(ascii: "+") where newLeft > 0:
                hunk.lines.append(LineDraft(kind: .added, oldNumber: nil, newNumber: newNumber, bytes: line.dropFirst()))
                newNumber += 1
                newLeft -= 1
            // An empty line is a blank context line whose leading space was
            // trimmed (diff.suppressBlankEmpty, or an editor).
            case UInt8(ascii: " ") where oldLeft > 0 && newLeft > 0, nil where oldLeft > 0 && newLeft > 0:
                hunk.lines.append(LineDraft(kind: .context, oldNumber: oldNumber, newNumber: newNumber, bytes: line.dropFirst()))
                oldNumber += 1
                newNumber += 1
                oldLeft -= 1
                newLeft -= 1
            default:
                // Truncated or malformed: keep what was read.
                return hunk
            }
            index += 1
        }
        while index < lines.count, lines[index].first == UInt8(ascii: "\\") {
            markNoNewline()
            index += 1
        }
        return hunk
    }

    // MARK: Files

    struct Builder {
        var gitOld: String?
        var gitNew: String?
        var oldPath: String?
        var newPath: String?
        var hasFileHeaders = false
        var renameFrom: String?
        var renameTo: String?
        var isNew = false
        var isDeleted = false
        var isRename = false
        var isBinary = false
        var isCombined = false
        var oldMode: String?
        var newMode: String?
        var similarity: Int?
        var hunks: [HunkDraft] = []

        mutating func setFileHeaders(old: ArraySlice<UInt8>, new: ArraySlice<UInt8>) {
            hasFileHeaders = true
            let oldName = UnifiedDiff.headerPath(old)
            let newName = UnifiedDiff.headerPath(new)
            if oldName == "/dev/null" { isNew = true } else { oldPath = UnifiedDiff.dropPrefix(oldName, "a/") }
            if newName == "/dev/null" { isDeleted = true } else { newPath = UnifiedDiff.dropPrefix(newName, "b/") }
        }

        mutating func readExtendedHeader(_ line: ArraySlice<UInt8>) {
            func value(_ prefix: String) -> ArraySlice<UInt8>? {
                let bytes = Array(prefix.utf8)
                return line.starts(with: bytes) ? line.dropFirst(bytes.count) : nil
            }
            func text(_ slice: ArraySlice<UInt8>) -> String { String(decoding: slice, as: UTF8.self) }
            if let mode = value("new file mode ") {
                isNew = true
                newMode = text(mode)
            } else if let mode = value("deleted file mode ") {
                isDeleted = true
                oldMode = text(mode)
            } else if let mode = value("old mode ") {
                oldMode = text(mode)
            } else if let mode = value("new mode ") {
                newMode = text(mode)
            } else if let name = value("rename from ") {
                isRename = true
                renameFrom = UnifiedDiff.unquote(name)
            } else if let name = value("rename to ") {
                isRename = true
                renameTo = UnifiedDiff.unquote(name)
            } else if let name = value("copy from ") {
                renameFrom = UnifiedDiff.unquote(name)
            } else if let name = value("copy to ") {
                renameTo = UnifiedDiff.unquote(name)
            } else if let score = value("similarity index ") {
                similarity = Int(text(score).trimmingCharacters(in: CharacterSet(charactersIn: "%")))
            } else if let index = value("index ") {
                // "index abc..def 100644": the mode both sides share.
                let parts = text(index).split(separator: " ")
                if parts.count == 2 {
                    let mode = String(parts[1])
                    if oldMode == nil, !isNew { oldMode = mode }
                    if newMode == nil, !isDeleted { newMode = mode }
                }
            } else if value("Binary files ") != nil || value("GIT binary patch") != nil {
                isBinary = true
            }
        }

        func build() -> File {
            var old = oldPath ?? renameFrom ?? (isNew ? nil : gitOld)
            var new = newPath ?? renameTo ?? (isDeleted ? nil : gitNew)
            if isNew { old = nil }
            if isDeleted { new = nil }

            let drafts = hunks.flatMap(\.lines)
            let oldSide = drafts.filter { $0.kind != .added }
            let newSide = drafts.filter { $0.kind != .removed }
            let oldStyle = UnifiedDiff.style(oldSide)
            let newStyle = UnifiedDiff.style(newSide)
            let speaksEnding = UnifiedDiff.style(drafts) == .mixed
            let built = hunks.enumerated().map { offset, hunk in
                Hunk(oldStart: hunk.header.oldStart, oldCount: hunk.header.oldCount,
                     newStart: hunk.header.newStart, newCount: hunk.header.newCount,
                     lines: hunk.lines.map {
                         DiffLine(kind: $0.kind, oldNumber: $0.oldNumber, newNumber: $0.newNumber,
                                  text: $0.text, ending: $0.ending, speaksEnding: speaksEnding)
                     },
                     number: offset + 1, total: hunks.count, numbersAreFileLines: true)
            }
            let path = new ?? old ?? ""
            let diff = FileDiff(
                toolName: GitChanges.toolName,
                path: path,
                cellID: nil,
                hunks: built,
                isNewFile: isNew,
                isApproximate: false,
                approximateReason: nil,
                addedCount: built.reduce(0) { $0 + $1.addedCount },
                removedCount: built.reduce(0) { $0 + $1.removedCount },
                oldMissingFinalNewline: oldSide.contains { !$0.hasNewline },
                newMissingFinalNewline: newSide.contains { !$0.hasNewline },
                oldLineEndings: oldStyle,
                newLineEndings: newStyle
            )
            return File(oldPath: old, newPath: new, isNew: isNew, isDeleted: isDeleted,
                        isRename: isRename && old != nil && new != nil && old != new,
                        isBinary: isBinary, oldMode: oldMode, newMode: newMode,
                        similarity: similarity, diff: diff)
        }
    }

    static func style(_ lines: [LineDraft]) -> LineEndingStyle {
        var sawLF = false
        var sawCRLF = false
        for line in lines {
            switch line.ending {
            case .lf: sawLF = true
            case .crlf: sawCRLF = true
            case nil: break
            }
        }
        switch (sawLF, sawCRLF) {
        case (false, false): return .none
        case (true, false): return .lf
        case (false, true): return .crlf
        case (true, true): return .mixed
        }
    }

    // MARK: Paths

    static func dropPrefix(_ path: String, _ prefix: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// The path on a "---" or "+++" line. Git puts a tab after a name with
    /// a space in it, and other diff tools a tab and a timestamp.
    static func headerPath(_ field: ArraySlice<UInt8>) -> String {
        if field.first == UInt8(ascii: "\"") { return unquote(field) }
        let name = field.firstIndex(of: UInt8(ascii: "\t")).map { field[..<$0] } ?? field
        return String(decoding: name, as: UTF8.self)
    }

    /// The two paths on a "diff --git a/x b/y" line, without prefixes.
    /// Unquoted paths with spaces are ambiguous here, so this splits them
    /// evenly when both sides name the same file; renames and new files
    /// get their real paths from the lines that follow.
    static func gitHeaderPaths(_ rest: ArraySlice<UInt8>) -> (String?, String?) {
        let space = UInt8(ascii: " ")
        let quote = UInt8(ascii: "\"")
        var old: String?
        var newField: ArraySlice<UInt8>
        if rest.first == quote {
            guard let (name, end) = quoted(rest) else { return (nil, nil) }
            old = name
            newField = rest[end...].drop { $0 == space }
        } else if rest.last == quote, let start = lastIndex(of: [space, quote], in: rest) {
            old = String(decoding: rest[..<start], as: UTF8.self)
            newField = rest[(start + 1)...]
        } else {
            // "a/X b/X": split in the middle when both halves match.
            let count = rest.count
            if count % 2 == 1 {
                let middle = rest.startIndex + count / 2
                let left = rest[..<middle]
                let right = rest[(middle + 1)...]
                if rest[middle] == space, left.dropFirst(2).elementsEqual(right.dropFirst(2)) {
                    return (dropPrefix(String(decoding: left, as: UTF8.self), "a/"),
                            dropPrefix(String(decoding: right, as: UTF8.self), "b/"))
                }
            }
            guard let split = firstIndex(of: Array(" b/".utf8), in: rest) else { return (nil, nil) }
            return (dropPrefix(String(decoding: rest[..<split], as: UTF8.self), "a/"),
                    String(decoding: rest[(split + 3)...], as: UTF8.self))
        }
        let new = newField.first == quote ? quoted(newField)?.0 : String(decoding: newField, as: UTF8.self)
        return (old.map { dropPrefix($0, "a/") }, new.map { dropPrefix($0, "b/") })
    }

    static func firstIndex(of needle: [UInt8], in haystack: ArraySlice<UInt8>) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        var index = haystack.startIndex
        while index + needle.count <= haystack.endIndex {
            if haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    static func lastIndex(of needle: [UInt8], in haystack: ArraySlice<UInt8>) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        var index = haystack.endIndex - needle.count
        while index >= haystack.startIndex {
            if haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index -= 1
        }
        return nil
    }

    /// A path git may have quoted (core.quotePath): C escapes and octal
    /// bytes inside double quotes. Unquoted text is returned as is.
    static func unquote(_ field: ArraySlice<UInt8>) -> String {
        if field.first == UInt8(ascii: "\""), let (name, _) = quoted(field) { return name }
        return String(decoding: field, as: UTF8.self)
    }

    /// Decodes a quoted string at the start of `field`; returns it and the
    /// index just past the closing quote.
    static func quoted(_ field: ArraySlice<UInt8>) -> (String, Int)? {
        guard field.first == UInt8(ascii: "\"") else { return nil }
        var bytes: [UInt8] = []
        var index = field.startIndex + 1
        while index < field.endIndex {
            let byte = field[index]
            if byte == UInt8(ascii: "\"") {
                return (String(decoding: bytes, as: UTF8.self), index + 1)
            }
            guard byte == UInt8(ascii: "\\") else {
                bytes.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < field.endIndex else { return nil }
            let escaped = field[index]
            switch escaped {
            case UInt8(ascii: "a"): bytes.append(7)
            case UInt8(ascii: "b"): bytes.append(8)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "v"): bytes.append(11)
            case UInt8(ascii: "f"): bytes.append(12)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = 0
                var digits = 0
                while digits < 3, index < field.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(field[index]) {
                    value = value * 8 + Int(field[index] - UInt8(ascii: "0"))
                    index += 1
                    digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                continue
            default:
                // \" and \\, and anything unknown, stand for themselves.
                bytes.append(escaped)
            }
            index += 1
        }
        return nil
    }
}

/// The lines a folder's uncommitted changes add and remove, as the toolbar's
/// changes button shows them ("+12 −3"), like the Claude app's changes pill.
public struct ChangeCounts: Sendable, Equatable {
    public let added: Int
    public let removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }

    /// Nil outside a git repository, where there's nothing to count.
    /// Tracked files only, as `git diff --shortstat` counts: an untracked
    /// file counts as wholly added, and IA's untracked build output made
    /// it "+488254" where git said 1,037.
    public init?(_ set: GitChangeSet) {
        guard case .repository(let repository) = set else { return nil }
        let tracked = repository.files.filter { $0.status != .untracked }
        self.init(
            added: tracked.reduce(0) { $0 + $1.addedCount },
            removed: tracked.reduce(0) { $0 + $1.removedCount }
        )
    }

    public var isEmpty: Bool { added == 0 && removed == 0 }

    /// "+12 −3", with a real minus sign.
    public var title: String { "+\(added) \u{2212}\(removed)" }

    /// "Uncommitted changes, 12 lines added, 3 removed".
    public var spoken: String { "Uncommitted changes, \(FileDiff.counts(added: added, removed: removed))" }
}

/// Set once a process has exited, from its termination handler.
final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// The header's line under the session title: the folder, then the branch
/// as the Claude app's header shows it.
public enum FolderLine {
    /// "ClaudeNative · main"; the folder alone outside a repository or with
    /// HEAD detached.
    public static func shown(folder: String, branch: String?) -> String {
        branch.map { "\(folder) \u{00B7} \($0)" } ?? folder
    }

    /// What VoiceOver hears: "ClaudeNative, on branch main", not a dot.
    public static func spoken(folder: String, branch: String?) -> String {
        branch.map { "\(folder), on branch \($0)" } ?? folder
    }
}

extension GitChangeSet {
    /// The checked-out branch; nil outside a repository or when detached.
    public var branch: String? {
        guard case .repository(let repository) = self else { return nil }
        return repository.branch
    }
}
