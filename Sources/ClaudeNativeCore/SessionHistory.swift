import Foundation
import Synchronization

/// Reads the CLI's saved sessions from disk. `--resume` does not replay old
/// messages on stdout, so this is the only way to show a resumed history.
///
/// The CLI keeps one JSONL file per session at
/// `<config dir>/projects/<encoded cwd>/<session id>.jsonl`. Subagent runs
/// live one level deeper (`<session id>/subagents/*.jsonl`) and are never
/// listed. Each line is one record with a top-level `type`; the ones that
/// carry conversation are `user` and `assistant`, and the rest (titles,
/// attachments, API request logs, cost, file-history snapshots) are skipped.
public enum SessionHistory {
    /// One saved session, as the open-session list shows it.
    public struct SessionSummary: Sendable, Equatable, Identifiable {
        public let id: String
        /// A short, single-line title that reads well when spoken.
        public let title: String
        public let lastModified: Date
        public let fileURL: URL
        /// The first prompt a person typed, on one line and cut at
        /// `maxSearchablePromptLength`, for the list's search field. Read
        /// once while listing so searching never opens a session file.
        public let firstPrompt: String
        /// The folder it runs in, when that isn't its section's: each "This
        /// computer" conversation has a scratch folder of its own.
        public var directory: URL?
        /// The project it belongs to, set when it's listed outside its
        /// project's section (grouped by date), so VoiceOver can say where.
        public var projectName: String?

        init(id: String, title: String, lastModified: Date, fileURL: URL, firstPrompt: String = "", directory: URL? = nil) {
            self.id = id
            self.title = title
            self.lastModified = lastModified
            self.fileURL = fileURL
            self.firstPrompt = firstPrompt
            self.directory = directory
        }
    }

    /// One session read back into transcript rows.
    public struct LoadedSession: Sendable, Equatable {
        public let id: String
        public let entries: [TranscriptEntry]
        /// Lines that were skipped and why, one string per reason with a count.
        public let diagnostics: [String]
    }

    public enum HistoryError: Error, Equatable {
        case sessionNotFound(id: String)
        case unreadable(path: String)
    }

    /// Longest title kept for the session list; longer prompts are cut at a
    /// word boundary so VoiceOver doesn't read a whole paragraph per row.
    static let maxTitleLength = 100
    /// Longest first prompt kept for search. Enough to hold what someone
    /// remembers asking, without keeping pasted logs in memory per row.
    static let maxSearchablePromptLength = 2_000
    /// The CLI cuts encoded folder names at this many characters and appends
    /// `-<hash>` to the rest.
    static let maxEncodedNameLength = 200

    // MARK: - Locating sessions

    /// `~/.claude/projects`, or `$CLAUDE_CONFIG_DIR/projects` when the CLI is
    /// pointed at another config folder.
    public static func defaultProjectsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configDir = environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            return URL(fileURLWithPath: configDir, isDirectory: true).appending(path: "projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
    }

    /// The folder name the CLI uses for a working directory: every UTF-16
    /// code unit that isn't an ASCII letter or digit becomes `-`.
    /// `/Users/me/App/.claude` becomes `-Users-me-App--claude`.
    public static func encodedDirectoryName(forPath path: String) -> String {
        String(String.UnicodeScalarView(path.utf16.map { unit in
            let isAlphanumeric = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
            return Unicode.Scalar(isAlphanumeric ? UInt8(unit) : UInt8(ascii: "-"))
        }))
    }

    /// The session folder for `cwd`, or nil when the CLI has never run there.
    /// The CLI records the resolved path (`/private/tmp/...`, not `/tmp/...`),
    /// so symlinks are resolved first. Names over 200 characters end in a hash
    /// we can't recompute, so those are matched by prefix and confirmed
    /// against the `cwd` recorded inside the folder's files.
    public static func projectDirectory(forCwd cwd: URL, projectsDirectory: URL) -> URL? {
        var candidates: [String] = []
        if let resolved = realPath(cwd.path) { candidates.append(resolved) }
        if !candidates.contains(cwd.path) { candidates.append(cwd.path) }

        let fileManager = FileManager.default
        for path in candidates {
            let name = encodedDirectoryName(forPath: path)
            if name.count <= maxEncodedNameLength {
                let folder = projectsDirectory.appending(path: name, directoryHint: .isDirectory)
                if isDirectory(folder) { return folder }
                continue
            }
            let prefix = String(name.prefix(maxEncodedNameLength)) + "-"
            let names = (try? fileManager.contentsOfDirectory(atPath: projectsDirectory.path)) ?? []
            let matches = names.filter { $0.hasPrefix(prefix) }.sorted()
            for match in matches {
                let folder = projectsDirectory.appending(path: match, directoryHint: .isDirectory)
                // Only a folder whose sessions recorded this cwd, anywhere in
                // them: a lone match was taken unchecked and listed a
                // sibling folder's sessions, and the first cwd alone missed a
                // conversation that moved into a worktree. A lone folder with
                // no cwd recorded at all is still taken.
                let recorded = recordedCwds(in: folder)
                if recorded.contains(path) || (matches.count == 1 && recorded.isEmpty) { return folder }
            }
        }
        return nil
    }

    // MARK: - Listing

    /// Saved sessions for `cwd`, newest first. Files with no prompt a person
    /// typed (empty runs, subagent-only files) are left out.
    public static func listSessions(
        cwd: URL,
        projectsDirectory: URL = defaultProjectsDirectory()
    ) -> [SessionSummary] {
        guard let folder = projectDirectory(forCwd: cwd, projectsDirectory: projectsDirectory) else { return [] }
        return listSessions(inProjectDirectory: folder)
    }

    /// Saved sessions in one project folder, newest first.
    public static func listSessions(inProjectDirectory folder: URL) -> [SessionSummary] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        var sessions: [SessionSummary] = []
        for file in files where file.pathExtension == "jsonl" {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let heading = heading(ofSessionFile: file) else { continue }
            sessions.append(SessionSummary(
                id: file.deletingPathExtension().lastPathComponent,
                title: heading.title,
                // Not the file's date: resuming appends records with no
                // timestamp, which would move a conversation to the top for
                // being opened.
                lastModified: heading.lastActivity ?? values?.contentModificationDate ?? .distantPast,
                fileURL: file,
                firstPrompt: heading.firstPrompt
            ))
        }
        return sessions.sorted {
            $0.lastModified != $1.lastModified ? $0.lastModified > $1.lastModified : $0.id < $1.id
        }
    }

    /// What the sidebar shows for a session file.
    struct Heading: Equatable {
        let title: String
        /// The first prompt on one line, for search.
        let firstPrompt: String
        /// When the last timestamped record was written, if any.
        var lastActivity: Date?
    }

    /// The title for one session file: a title the user set, else the CLI's
    /// generated one, else a legacy `summary` line, else the first prompt.
    /// Nil when the file has no prompt a person typed. The first prompt
    /// comes back too, on one line, for search.
    ///
    /// Titles are found by searching the mapped file backwards for the last
    /// record of each kind, and the first prompt by reading lines only until
    /// it: splitting all 341 files (2.1 GB) into lines took 17 s. Results are
    /// kept per file until its size or modification date changes.
    static func heading(ofSessionFile file: URL) -> Heading? {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = HeadingCache.Stamp(size: values?.fileSize ?? -1, modified: values?.contentModificationDate ?? .distantPast)
        if let cached = HeadingCache.shared.entry(for: file, stamp: stamp) { return cached.heading }
        let heading = readHeading(ofSessionFile: file)
        HeadingCache.shared.store(heading, for: file, stamp: stamp)
        return heading
    }

    static func readHeading(ofSessionFile file: URL) -> Heading? {
        guard let reader = LineReader(url: file) else { return nil }
        var firstPrompt: String?
        // Only lines that can matter are decoded; JSON escapes quotes inside
        // strings, so these markers can't match message text.
        while firstPrompt == nil, let line = reader.next() {
            guard line.contains(Marker.user),
                  let value = try? JSONValue.parse(line), value["type"]?.string == "user" else { continue }
            // A file that opens with sidechain lines is a subagent run.
            if value["isSidechain"]?.bool == true { return nil }
            firstPrompt = promptText(of: value)
        }
        guard let firstPrompt else { return nil }
        let mapped = try? Data(contentsOf: file, options: .alwaysMapped)
        let titles = mapped.map { data in
            [
                lastValue(of: "customTitle", after: Marker.customTitle, in: data),
                lastValue(of: "aiTitle", after: Marker.aiTitle, in: data),
                lastValue(of: "summary", after: Marker.summary, in: data),
            ]
        } ?? []
        let chosen = (titles + [firstPrompt])
            .compactMap { $0.map(speakable) }
            .first { !$0.isEmpty }
        let searchable = firstPrompt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .prefix(maxSearchablePromptLength)
        return Heading(
            title: chosen ?? speakable(firstPrompt),
            firstPrompt: String(searchable),
            lastActivity: mapped.flatMap(lastTimestamp)
        )
    }

    /// The `timestamp` of the last line that has one. Lines are walked back
    /// from the end, so this reads only the records after the last message.
    static func lastTimestamp(in data: Data) -> Date? {
        data.withUnsafeBytes { raw -> Date? in
            guard let base = raw.baseAddress else { return nil }
            return Marker.timestamp.withUnsafeBytes { needle -> Date? in
                guard let needleBase = needle.baseAddress else { return nil }
                var end = raw.count
                while end > 0 {
                    var start = end
                    while start > 0, raw[start - 1] != newline { start -= 1 }
                    if let hit = memmem(base + start, end - start, needleBase, needle.count) {
                        let valueStart = base.distance(to: hit) + needle.count
                        var valueEnd = valueStart
                        while valueEnd < end, raw[valueEnd] != UInt8(ascii: "\"") { valueEnd += 1 }
                        let text = String(decoding: UnsafeRawBufferPointer(rebasing: raw[valueStart..<valueEnd]), as: UTF8.self)
                        if let date = timestampFormat.date(from: text) ?? wholeSecondFormat.date(from: text) { return date }
                    }
                    end = start - 1
                }
                return nil
            }
        }
    }

    private nonisolated(unsafe) static let timestampFormat: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()

    private nonisolated(unsafe) static let wholeSecondFormat = ISO8601DateFormatter()

    /// `key` from the last line holding `marker` that parses and has it.
    /// The lines holding it are found with memmem, which is vectorized;
    /// Data's own backwards search took seconds over a 2 GB history.
    private static func lastValue(of key: String, after marker: Data, in data: Data) -> String? {
        let lines: [Range<Int>] = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return [] }
            return marker.withUnsafeBytes { needle -> [Range<Int>] in
                guard let needleBase = needle.baseAddress else { return [] }
                var found: [Range<Int>] = []
                var offset = 0
                while offset < raw.count,
                      let hit = memmem(base + offset, raw.count - offset, needleBase, needle.count) {
                    let at = base.distance(to: hit)
                    var start = at, end = at
                    while start > 0, raw[start - 1] != newline { start -= 1 }
                    while end < raw.count, raw[end] != newline { end += 1 }
                    found.append(start..<end)
                    offset = end
                }
                return found
            }
        }
        for line in lines.reversed() {
            let bytes = data[data.startIndex + line.lowerBound..<data.startIndex + line.upperBound]
            if let value = (try? JSONValue.parse(Data(bytes)))?[key]?.string { return value }
        }
        return nil
    }

    // MARK: - Loading

    public static func loadSession(
        id: String,
        cwd: URL,
        projectsDirectory: URL = defaultProjectsDirectory()
    ) throws -> LoadedSession {
        guard let folder = projectDirectory(forCwd: cwd, projectsDirectory: projectsDirectory) else {
            throw HistoryError.sessionNotFound(id: id)
        }
        let file = folder.appending(path: "\(id).jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { throw HistoryError.sessionNotFound(id: id) }
        return try loadSession(fileURL: file)
    }

    /// Reads a session file into the rows the live transcript would have
    /// shown: one row per typed prompt, one per assistant message id, one per
    /// tool call with the status its result gave it. The file is read a line
    /// at a time, so memory stays flat however long the session ran.
    public static func loadSession(fileURL: URL) throws -> LoadedSession {
        guard let reader = LineReader(url: fileURL) else { throw HistoryError.unreadable(path: fileURL.path) }
        var transcript = Transcript()
        var skipped = SkipCounter()
        // Resumed and forked sessions rewrite earlier lines with the same
        // uuid; each record is applied once.
        var seenUUIDs: Set<String> = []

        while let line = reader.next() {
            guard !line.allSatisfy(isWhitespace) else { continue }
            // The header is decoded on its own, then messages parsed again.
            // Tried and dropped (2026-10-27, fixtures plus two real
            // sessions, same output): parsing every line once was 17%
            // slower, since skipped lines were then built in full; parsing
            // once only lines with a message marker saved 3.5%.
            guard let head = try? JSONDecoder().decode(LineHead.self, from: line) else {
                skipped.add("unreadable line")
                continue
            }
            guard let type = head.type else {
                skipped.add("line with no type")
                continue
            }
            guard type == "user" || type == "assistant" else {
                if !ignoredTypes.contains(type) { skipped.add("unknown line type \"\(type)\"") }
                continue
            }
            if head.isSidechain == true { continue }
            if let uuid = head.uuid, !seenUUIDs.insert(uuid).inserted { continue }
            guard let value = try? JSONValue.parse(line) else {
                skipped.add("unreadable \(type) line")
                continue
            }
            if type == "assistant" {
                guard let message = value["message"], let messageID = message["id"]?.string else {
                    skipped.add("assistant line with no message id")
                    continue
                }
                let blocks = (message["content"]?.array ?? []).compactMap(ContentBlock.read)
                transcript.apply(.assistantMessage(messageID: messageID, blocks: blocks), at: nil)
            } else if let results = toolResults(of: value) {
                for result in results { transcript.apply(result) }
                // Saved files say why a tool was refused; Stop cutting one
                // off is recorded as "interrupted", which the user didn't
                // refuse.
                if let kind = value["toolDenialKind"]?.string, kind != "interrupted" {
                    for case .toolResult(let toolUseID, _, _) in results { transcript.markDenied(toolUseID: toolUseID) }
                }
            } else if let text = promptText(of: value) {
                transcript.appendUser(text, id: head.uuid ?? UUID().uuidString)
            }
        }

        // A call with no recorded result never finished (the process was
        // killed mid-call). Nothing will resume it, so it can't stay "running".
        var unfinished = 0
        for entry in transcript.entries {
            guard case .tool(_, let status) = entry.kind, status == .running || status == .awaitingPermission else { continue }
            transcript.apply(.toolResult(toolUseID: String(entry.id.dropFirst("tool:".count)), text: "", isError: true))
            unfinished += 1
        }
        if unfinished > 0 { skipped.add("tool call with no result, shown as failed", count: unfinished) }

        return LoadedSession(
            id: fileURL.deletingPathExtension().lastPathComponent,
            entries: transcript.entries,
            diagnostics: skipped.descriptions + transcript.diagnostics
        )
    }

    // MARK: - Reading user lines

    /// Line types the CLI writes that carry nothing for the transcript.
    static let ignoredTypes: Set<String> = [
        "system", "attachment", "summary", "custom-title", "ai-title", "agent-name", "last-prompt",
        "queue-operation", "file-history-snapshot", "file-history-delta", "mode", "cost-state",
        "atis-latch", "bridge-session", "api-request", "api-request-blob", "api-request-shape",
        "frame-link", "pr-link", "relocated", "worktree-state", "dev-mods",
        "artifact-comment-monitor", "artifact-autoreact-ledger", "progress", "tag",
    ]

    /// Text the CLI writes into user lines that the person didn't type:
    /// slash-command echoes, local command output, background task
    /// notifications, and interrupt markers.
    static let injectedPrefixes = [
        "<command-name>", "<command-message>", "<command-args>", "<command-contents>",
        "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>",
        "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<task-notification>",
        "[Request interrupted by user", "Caveat: The messages below were generated by the user",
    ]

    /// The tool results a user line carries, or nil when it carries none.
    static func toolResults(of line: JSONValue) -> [StreamEvent]? {
        let results = StreamEvent.toolResults(in: line)
        return results.isEmpty ? nil : results
    }

    /// What the person typed on a `user` line, or nil when the line is
    /// something the CLI added: meta lines (`isMeta`), compaction summaries,
    /// transcript-only lines, messages from other agents or background tasks
    /// (`origin.kind` other than `human`), and injected context elements such
    /// as `<system-reminder>`.
    static func promptText(of line: JSONValue) -> String? {
        for flag in ["isMeta", "isCompactSummary", "isVisibleInTranscriptOnly", "isSidechain"]
        where line[flag]?.bool == true {
            return nil
        }
        if let origin = line["origin"]?["kind"]?.string, origin != "human" { return nil }

        let pieces: [String]
        switch line["message"]?["content"] {
        case .string(let text):
            pieces = [text]
        case .array(let blocks):
            if blocks.contains(where: { $0["type"]?.string == "tool_result" }) { return nil }
            pieces = blocks.map { TranscriptContent.blockText($0) }
        default:
            return nil
        }
        let text = pieces
            .map { removingInjectedElements($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        // A slash command or `!` shell line is stored as tags; show it the
        // way it was typed.
        if text.hasPrefix("<command-"), let command = contents(ofTag: "command-name", in: text) {
            let arguments = contents(ofTag: "command-args", in: text) ?? ""
            return arguments.isEmpty ? command : "\(command) \(arguments)"
        }
        if text.hasPrefix("<bash-input>"), let shell = contents(ofTag: "bash-input", in: text) { return "! \(shell)" }
        let typed = removingPastedContentTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !injectedPrefixes.contains(where: typed.hasPrefix) else { return nil }
        return typed
    }

    /// The trimmed text between the first `<tag>` and `</tag>`.
    static func contents(ofTag tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text[open.upperBound...].range(of: "</\(tag)>")
        else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The desktop app wraps pasted text in `<pasted_content id="…">` tags;
    /// the person pasted only what's inside.
    static func removingPastedContentTags(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<pasted_content") {
            result += rest[..<open.lowerBound]
            guard let end = rest[open.upperBound...].firstIndex(of: ">") else { return result + rest[open.lowerBound...] }
            rest = rest[rest.index(after: end)...]
        }
        return (result + rest).replacingOccurrences(of: "</pasted_content>", with: "")
    }

    /// Context the CLI or the desktop app adds to a user turn as a whole
    /// element: reminders, other sessions' events, the artifact being viewed.
    static let injectedElements = [
        "system-reminder", "side-sessions-event", "artifact-view-context", "cross-session-message",
    ]

    /// `text` with every injected element (open tag, with or without
    /// attributes, through its close tag) cut out. An element with no close
    /// tag runs to the end.
    static func removingInjectedElements(_ text: String) -> String {
        var text = text
        for tag in injectedElements {
            var result = ""
            var rest = Substring(text)
            while let open = rest.range(of: "<\(tag)"),
                  let next = rest[open.upperBound...].first, next == ">" || next == " " {
                result += rest[..<open.lowerBound]
                guard let close = rest[open.upperBound...].range(of: "</\(tag)>") else {
                    rest = ""
                    break
                }
                rest = rest[close.upperBound...]
            }
            text = result + rest
        }
        return text
    }

    /// One line, whitespace collapsed, cut at a word boundary.
    static func speakable(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        var title = ""
        for word in words {
            let next = title.isEmpty ? String(word) : title + " " + word
            if next.count > maxTitleLength {
                if title.isEmpty { title = String(word.prefix(maxTitleLength)) }
                return title + "…"
            }
            title = next
        }
        return title
    }

    // MARK: - File helpers

    private enum Marker {
        static let user = Data(#""type":"user""#.utf8)
        static let customTitle = Data(#""type":"custom-title""#.utf8)
        static let aiTitle = Data(#""type":"ai-title""#.utf8)
        static let summary = Data(#""type":"summary""#.utf8)
        static let cwd = Data(#""cwd":"#.utf8)
        static let timestamp = Data(#""timestamp":""#.utf8)
    }

    private struct LineHead: Decodable {
        let type: String?
        let uuid: String?
        let isSidechain: Bool?
    }

    private struct SkipCounter {
        private var counts: [(reason: String, count: Int)] = []
        mutating func add(_ reason: String, count: Int = 1) {
            if let index = counts.firstIndex(where: { $0.reason == reason }) {
                counts[index].count += count
            } else {
                counts.append((reason, count))
            }
        }
        var descriptions: [String] { counts.map { "skipped \($0.count) × \($0.reason)" } }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The first `cwd` recorded in any session file in `folder`.
    /// Every distinct cwd the folder's session files recorded.
    private static func recordedCwds(in folder: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found = Set<String>()
        for file in files where file.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
            found.formUnion(recordedCwds(in: data))
        }
        return found
    }
}

private extension Data {
    func contains(_ needle: Data) -> Bool { range(of: needle) != nil }
}

/// Reads a file one newline-terminated line at a time in fixed-size chunks.
final class LineReader {
    private static let chunkSize = 1 << 20
    private let handle: FileHandle
    private var buffer = Data()
    private var atEnd = false

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
    }

    deinit { try? handle.close() }

    /// memchr over the bytes: Data's generic firstIndex(of:) went a byte at
    /// a time through its subscript, 0.92 s of a 92 MB session's 2.2 s load.
    private static func firstNewline(in data: Data) -> Data.Index? {
        data.withUnsafeBytes { bytes -> Data.Index? in
            guard let base = bytes.baseAddress, let hit = memchr(base, 0x0A, bytes.count) else { return nil }
            return data.startIndex + (UnsafeRawPointer(hit) - base)
        }
    }

    func next() -> Data? {
        while true {
            if let newline = Self.firstNewline(in: buffer) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[(newline + 1)...]
                return Data(line)
            }
            if atEnd {
                guard !buffer.isEmpty else { return nil }
                defer { buffer = Data() }
                return Data(buffer)
            }
            let chunk = (try? handle.read(upToCount: Self.chunkSize)) ?? nil
            if let chunk, !chunk.isEmpty {
                // Re-base so indices stay small and the consumed prefix is freed.
                buffer = Data(buffer) + chunk
            } else {
                atEnd = true
            }
        }
    }
}

// MARK: - Renaming and deleting

extension SessionHistory {
    public enum ChangeError: Error, Equatable {
        case emptyTitle
        /// Not a session file the CLI wrote, so it isn't changed.
        case notASessionFile(path: String)
    }

    /// Titles a session as the CLI's `/rename` does: a `custom-title` record
    /// at the end of its file, which listing reads over any earlier title.
    /// A fork's title: the original's with "(fork)" after it, once, so a
    /// fork of a fork doesn't pile them up.
    public static func forkTitle(_ title: String) -> String {
        title.hasSuffix(forkSuffix) ? title : title + forkSuffix
    }

    static let forkSuffix = " (fork)"

    public static func rename(_ session: SessionSummary, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChangeError.emptyTitle }
        try requireSessionFile(session)
        let record = ["type": "custom-title", "customTitle": trimmed, "sessionId": session.id]
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(newline)
        if try !endsWithNewline(session.fileURL) { line.insert(newline, at: 0) }
        // Append mode, as the CLI writes: each write lands at the true end,
        // so a line the CLI adds meanwhile is never written over. Seeking to
        // the end and then writing lost lines while a reply streamed.
        // O_CLOEXEC: a CLI started at the same moment mustn't inherit it.
        let descriptor = open(session.fileURL.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: session.fileURL.path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: line)
    }

    /// Whether the file's last byte is a line break (true when it's empty).
    private static func endsWithNewline(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard end > 0 else { return true }
        try handle.seek(toOffset: end - 1)
        return try handle.read(upToCount: 1) == Data([newline])
    }

    /// Hands `remove` the folder of the same name that holds the session's
    /// subagent runs, if there is one, then its file: should the folder
    /// fail, the conversation is still whole. The app passes moving
    /// to the Trash, so a deletion can be undone from the Finder.
    public static func delete(
        _ session: SessionSummary,
        using remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        try requireSessionFile(session)
        let companion = session.fileURL.deletingPathExtension()
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: companion.path, isDirectory: &isFolder), isFolder.boolValue {
            try remove(companion)
        }
        try remove(session.fileURL)
    }

    static let newline = UInt8(ascii: "\n")

    /// A `.jsonl` file named by its session id, a UUID as the CLI names
    /// them. Anything else is left alone.
    private static func requireSessionFile(_ session: SessionSummary) throws {
        let file = session.fileURL
        guard file.pathExtension == "jsonl",
              file.deletingPathExtension().lastPathComponent == session.id,
              UUID(uuidString: session.id) != nil
        else { throw ChangeError.notASessionFile(path: file.path) }
    }
}

extension SessionHistory.ChangeError {
    /// What VoiceOver says when a rename fails, with the reason: "Couldn't
    /// rename the conversation. Permission denied."
    public static func renameFailureWording(_ error: Error) -> String {
        let reason: String
        switch error {
        case let posix as POSIXError: reason = String(cString: strerror(posix.code.rawValue))
        case SessionHistory.ChangeError.emptyTitle: reason = "The title is empty"
        case SessionHistory.ChangeError.notASessionFile: reason = "It isn't a session file"
        default: reason = error.localizedDescription
        }
        return "Couldn't rename the session. \(reason)."
    }
}

/// Titles already read, per file, until the file changes.
final class HeadingCache: @unchecked Sendable {
    static let shared = HeadingCache()

    struct Stamp: Equatable {
        let size: Int
        let modified: Date
    }

    struct Entry {
        let stamp: Stamp
        let heading: SessionHistory.Heading?
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func entry(for file: URL, stamp: Stamp) -> Entry? {
        lock.withLock { entries[file].flatMap { $0.stamp == stamp ? $0 : nil } }
    }

    func store(_ heading: SessionHistory.Heading?, for file: URL, stamp: Stamp) {
        lock.withLock { entries[file] = Entry(stamp: stamp, heading: heading) }
    }
}

// MARK: - Projects

extension SessionHistory {
    /// One folder the CLI has saved conversations for, as the sidebar
    /// shows it: a section named by the folder, holding its conversations.
    public struct ProjectSummary: Sendable, Equatable, Identifiable {
        /// The working folder the conversations ran in.
        public let directory: URL
        /// The folder's name, with its parent added when another project
        /// has the same name ("enchanted · ~/Documents").
        public let name: String
        /// Newest first.
        public let sessions: [SessionSummary]
        /// False for "This computer", which has no folder to start in.
        public let startsConversations: Bool

        public var id: String { directory.path }

        public init(directory: URL, name: String, sessions: [SessionSummary], startsConversations: Bool = true) {
            self.directory = directory
            self.name = name
            self.sessions = sessions
            self.startsConversations = startsConversations
        }

        /// The Claude app's name for its no-folder conversations.
        public static let thisComputerName = "This computer"
        /// The section of pinned conversations, first in the list.
        public static let pinnedName = "Pinned"
        /// Stands in for the Pinned section's folder: it has none, and its
        /// conversations resume in their own. Also its identity for folding.
        public static let pinnedDirectory = URL(fileURLWithPath: "/", isDirectory: true).appending(path: "Pinned conversations")
    }

    /// Newest first, ties by id, as every list here sorts conversations.
    static func newestFirst(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.sorted { $0.lastModified != $1.lastModified ? $0.lastModified > $1.lastModified : $0.id < $1.id }
    }

    /// Every project with a conversation in it, the most recently used
    /// first. A folder that no longer exists is left out, since a
    /// conversation can't be resumed without it, and so is one under
    /// `hiding`: the system's temporary space, where test runs and scripted
    /// sessions leave throwaway folders. Saved folders for one working
    /// folder (reached through a symlink, say) are one project.
    ///
    /// Conversations in folders under `gathering`, the Claude app's scratch
    /// workspaces, are one "This computer" section after the projects, as
    /// the Claude app shows them, each resuming in its own folder.
    public static func listProjects(
        projectsDirectory: URL = defaultProjectsDirectory(),
        hiding: [String] = temporaryRoots,
        gathering: String = claudeScratchRoot
    ) -> [ProjectSummary] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        var byPath: [String: (directory: URL, sessions: [SessionSummary])] = [:]
        var gathered: [SessionSummary] = []
        for folder in folders where isDirectory(folder) {
            let sessions = listSessions(inProjectDirectory: folder)
            guard !sessions.isEmpty, let cwd = projectCwd(in: folder) else { continue }
            let directory = URL(fileURLWithPath: cwd, isDirectory: true)
            guard isDirectory(directory), !isTemporary(directory, roots: hiding) else { continue }
            if isTemporary(directory, roots: [gathering]) {
                gathered += sessions.map { session in
                    var placed = session
                    placed.directory = directory
                    return placed
                }
                continue
            }
            // A worktree's conversations belong to its repository, as the
            // Claude app lists them, each resuming in its own worktree.
            if let repository = repository(ofWorktree: directory), isDirectory(repository) {
                byPath[canonicalPath(repository), default: (repository, [])].sessions += sessions.map { session in
                    var placed = session
                    placed.directory = directory
                    return placed
                }
                continue
            }
            let key = canonicalPath(directory)
            byPath[key, default: (directory, [])].sessions += sessions
        }
        var found = byPath.values.map { (directory: $0.directory, sessions: newestFirst($0.sessions)) }
        found.sort {
            let (left, right) = ($0.sessions.first?.lastModified ?? .distantPast, $1.sessions.first?.lastModified ?? .distantPast)
            return left != right ? left > right : $0.directory.path < $1.directory.path
        }
        let names = projectNames(for: found.map(\.directory))
        var projects = zip(found, names).map { ProjectSummary(directory: $0.directory, name: $1, sessions: $0.sessions) }
        if !gathered.isEmpty {
            projects.append(ProjectSummary(
                directory: URL(fileURLWithPath: gathering, isDirectory: true),
                name: ProjectSummary.thisComputerName,
                sessions: newestFirst(gathered),
                startsConversations: false
            ))
        }
        return projects
    }

    /// The repository a Claude Code worktree (`<repository>/.claude/worktrees/<name>`)
    /// was made from, or nil for any other folder.
    public static func repository(ofWorktree directory: URL) -> URL? {
        let components = directory.standardizedFileURL.pathComponents
        guard let marker = components.lastIndex(of: ".claude"), marker > 1,
              components.indices.contains(marker + 2), components[marker + 1] == "worktrees" else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<marker])), isDirectory: true)
    }

    /// The Claude app's scratch workspaces, where its no-folder sessions run.
    public static let claudeScratchRoot = canonicalPath(
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Claude/scratch-workspaces")
    )

    /// Where test runs and scripted sessions leave throwaway folders.
    public static let temporaryRoots: [String] = Array(Set([
        canonicalPath(URL(fileURLWithPath: NSTemporaryDirectory())),
        "/private/tmp",
        "/private/var/folders",
    ]))

    /// Whether `url` is inside one of `roots`.
    public static func isTemporary(_ url: URL, roots: [String] = temporaryRoots) -> Bool {
        let path = canonicalPath(url)
        return roots.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// The working folder a saved folder belongs to: of the `cwd`s its
    /// files record, the one the folder is named for. A conversation that
    /// moved into a worktree first records the repository but is saved,
    /// and resumes, under the worktree.
    static func projectCwd(in folder: URL) -> String? {
        // A folder is named for its working folder, so a match, once found,
        // stays right; worked out on each refresh it read every session
        // file, about 636 MB on a real account (0.5 s warm, 7.6 s cold).
        if let known = cwdCache.withLock({ $0[folder.path] }) { return known }
        let name = folder.lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var first: String?
        for file in files where file.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
            for cwd in recordedCwds(in: data) {
                first = first ?? cwd
                let encoded = encodedDirectoryName(forPath: cwd)
                let matches = encoded.count <= maxEncodedNameLength
                    ? encoded == name
                    : name.hasPrefix(String(encoded.prefix(maxEncodedNameLength)) + "-")
                if matches {
                    cwdCache.withLock { $0[folder.path] = cwd }
                    return cwd
                }
            }
        }
        // A fallback isn't kept: a later file may record the right one.
        return first
    }

    private static let cwdCache = Mutex<[String: String]>([:])

    /// Each distinct `cwd` value in a session file, in order, found with
    /// memmem rather than by splitting the file into lines.
    private static func recordedCwds(in data: Data) -> [String] {
        let marker = Data(#""cwd":""#.utf8)
        let quote = UInt8(ascii: "\"")
        return data.withUnsafeBytes { raw -> [String] in
            guard let base = raw.baseAddress else { return [] }
            return marker.withUnsafeBytes { needle -> [String] in
                guard let needleBase = needle.baseAddress else { return [] }
                var seen: [String] = []
                var offset = 0
                while offset < raw.count,
                      let hit = memmem(base + offset, raw.count - offset, needleBase, needle.count) {
                    let start = base.distance(to: hit) + needle.count
                    var end = start
                    while end < raw.count, raw[end] != quote { end += 1 }
                    let value = String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<end]), as: UTF8.self)
                    if !seen.contains(value) { seen.append(value) }
                    offset = end
                }
                return seen
            }
        }
    }

    /// Each folder's name, as the Claude app shows projects. A worktree is
    /// "repository · worktree", short to read and hear where its path isn't.
    /// Projects whose names match, case aside, add where they are: the
    /// parent folder, with the home folder as `~`.
    public static func projectNames(
        for directories: [URL],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let names = directories.map { directory -> String in
            let components = directory.standardizedFileURL.pathComponents
            if let marker = components.lastIndex(of: ".claude"), marker > 1,
               components.indices.contains(marker + 2), components[marker + 1] == "worktrees" {
                return "\(components[marker - 1]) · \(directory.lastPathComponent)"
            }
            return directory.lastPathComponent
        }
        // Case aside: "Enchanted" and "enchanted" sound the same.
        let counts = Dictionary(names.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        return zip(directories, names).map { directory, name in
            counts[name.lowercased(), default: 0] > 1
                ? "\(name) · \(abbreviated(directory.deletingLastPathComponent(), home: home))"
                : name
        }
    }

    /// `listed` with the window's folder in it: that folder's section shows
    /// `sessions`, the window's own fresher list, and comes first when it
    /// has no conversations yet. Names are worked out again, since the
    /// added folder can share a name with another.
    public static func projects(
        _ listed: [ProjectSummary],
        current: URL?,
        sessions: [SessionSummary],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ProjectSummary] {
        // "This computer" keeps its name and place; its folders aren't projects.
        let gatheredSections = listed.filter { !$0.startsConversations }
        var entries = listed.filter(\.startsConversations).map { (directory: $0.directory, sessions: $0.sessions) }
        if let current, !gatheredSections.contains(where: { isTemporary(current, roots: [canonicalPath($0.directory)]) }) {
            let key = canonicalPath(current)
            if let index = entries.firstIndex(where: { canonicalPath($0.directory) == key }) {
                // The repository's own conversations; its worktrees' stay.
                entries[index].sessions = newestFirst(
                    entries[index].sessions.filter { $0.directory.map(canonicalPath).map { $0 != key } ?? false } + sessions
                )
            } else if let repository = repository(ofWorktree: current),
                      let index = entries.firstIndex(where: { canonicalPath($0.directory) == canonicalPath(repository) }) {
                // A window in a worktree shows its fresher list in the
                // repository's section, in place of what was listed for it.
                let placed = sessions.map { session in
                    var placed = session
                    placed.directory = current
                    return placed
                }
                entries[index].sessions = newestFirst(
                    entries[index].sessions.filter { $0.directory.map(canonicalPath) != key } + placed
                )
            } else {
                entries.insert((current, sessions), at: 0)
            }
        }
        let names = projectNames(for: entries.map(\.directory), home: home)
        return zip(entries, names).map { ProjectSummary(directory: $0.directory, name: $1, sessions: $0.sessions) }
            + gatheredSections
    }

    /// `projects` with the conversations in `pinned` moved to a "Pinned"
    /// section first, newest first, as in the Claude app. Each keeps its
    /// project's folder to resume in; a project left empty goes.
    public static func pinning(_ projects: [ProjectSummary], pinned: Set<String>) -> [ProjectSummary] {
        guard !pinned.isEmpty else { return projects }
        var moved: [SessionSummary] = []
        let rest = projects.compactMap { project -> ProjectSummary? in
            let (pins, others) = (project.sessions.filter { pinned.contains($0.id) }, project.sessions.filter { !pinned.contains($0.id) })
            moved += pins.map { session in
                var placed = session
                placed.directory = session.directory ?? project.directory
                // Away from its project's heading, the row says which it
                // came from, as rows grouped by date do.
                placed.projectName = session.projectName ?? project.name
                return placed
            }
            if pins.isEmpty { return project }
            return others.isEmpty ? nil : ProjectSummary(
                directory: project.directory, name: project.name, sessions: others,
                startsConversations: project.startsConversations
            )
        }
        guard !moved.isEmpty else { return projects }
        let section = ProjectSummary(
            directory: ProjectSummary.pinnedDirectory, name: ProjectSummary.pinnedName,
            sessions: newestFirst(moved), startsConversations: false
        )
        return [section] + rest
    }

    /// A date section of the sidebar, as the Claude app's Group by Date.
    public enum DateGroup: String, CaseIterable, Sendable {
        case today = "Today"
        case yesterday = "Yesterday"
        case previousSevenDays = "Previous 7 Days"
        case older = "Older"

        /// Stands in for the section's folder, as Pinned's does.
        public var directory: URL {
            URL(fileURLWithPath: "/", isDirectory: true).appending(path: "Sessions \(rawValue)")
        }

        static func of(_ date: Date, now: Date, calendar: Calendar) -> DateGroup {
            let startOfToday = calendar.startOfDay(for: now)
            // From today on, a date ahead of the clock (another Mac's)
            // included: it went under Yesterday.
            if date >= startOfToday { return .today }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday), date >= yesterday { return .yesterday }
            if let week = calendar.date(byAdding: .day, value: -7, to: startOfToday), date >= week { return .previousSevenDays }
            return .older
        }
    }

    /// `projects` regrouped by when each session was last used: Today,
    /// Yesterday, Previous 7 Days, Older, newest first in each, empty
    /// groups left out. A Pinned section stays first as it is. Each
    /// session keeps its own folder to resume in and its project's name.
    public static func byDate(_ projects: [ProjectSummary], now: Date = .now, calendar: Calendar = .current) -> [ProjectSummary] {
        let pinned = projects.filter { $0.directory == ProjectSummary.pinnedDirectory }
        var groups: [DateGroup: [SessionSummary]] = [:]
        for project in projects where project.directory != ProjectSummary.pinnedDirectory {
            for session in project.sessions {
                var placed = session
                placed.directory = session.directory ?? project.directory
                placed.projectName = project.name
                groups[DateGroup.of(session.lastModified, now: now, calendar: calendar), default: []].append(placed)
            }
        }
        let dated = DateGroup.allCases.compactMap { group -> ProjectSummary? in
            guard let sessions = groups[group], !sessions.isEmpty else { return nil }
            return ProjectSummary(directory: group.directory, name: group.rawValue, sessions: newestFirst(sessions), startsConversations: false)
        }
        return pinned + dated
    }

    /// The sessions Command-1 to Command-9 open, in the sidebar's order:
    /// top to bottom, leaving out folded projects, whose rows aren't shown.
    public static func numbered(_ projects: [ProjectSummary], folded: Set<String>, count: Int = 9) -> [SessionSummary] {
        Array(projects.filter { !folded.contains($0.id) }.flatMap(\.sessions).prefix(count))
    }

    /// A folder's path with symlinks resolved, as the CLI records it.
    /// A folder that doesn't exist (yet) takes its nearest existing
    /// parent's resolved path, so /tmp/new matches /private/tmp.
    public static func canonicalPath(_ url: URL) -> String {
        var tail: [String] = []
        var current = url.standardizedFileURL
        while current.path != "/" {
            if let resolved = realPath(current.path) {
                return tail.reversed().reduce(resolved) { $0 + "/" + $1 }
            }
            tail.append(current.lastPathComponent)
            current = current.deletingLastPathComponent()
        }
        return url.standardizedFileURL.path
    }

    /// `path` with the home folder written as `~`.
    static func abbreviated(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
