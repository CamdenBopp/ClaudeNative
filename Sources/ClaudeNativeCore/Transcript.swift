import Foundation

/// One row of the conversation. `id` never changes once the entry exists, so
/// the view layer can keep exactly one accessibility element per entry for
/// the life of the conversation (VoiceOver hot spots point at that element).
public struct TranscriptEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case user
        case assistant
        case tool(name: String, status: ToolStatus)
        /// One block of Claude's extended thinking. While it streams the text
        /// can be empty; once finished it is never empty (see
        /// `thinkingPlaceholder`).
        case thinking(isFinished: Bool)
        case notice
    }

    /// A finished thinking row's text when the CLI sent none of the thinking
    /// itself (the default display, or a redacted block): Claude thought,
    /// and that is all anyone can say.
    public static let thinkingPlaceholder = "Thinking"

    public enum ToolStatus: Sendable, Equatable {
        /// Asked for and waiting on the user's answer; nothing runs yet.
        case awaitingPermission
        case running
        case succeeded
        case failed
        /// The user refused it; it never ran.
        case denied
    }

    public let id: String
    public var kind: Kind
    public var text: String
    /// A tool row's input, for showing what it changed or opening its file.
    public var toolInput: JSONValue? = nil
    /// When this app saw a tool row start, so a running row can say how
    /// long it has run. Nil for rows read back from a saved session.
    public var startedAt: Date? = nil
    /// What a tool row's tool returned (a command's output, a file's text),
    /// cut at `maxToolOutputLength`; nil until it returns or when empty.
    public var output: String? = nil

    /// The longest tool output kept on a row: enough for a long build log's
    /// end to matter less than a session's memory.
    public static let maxToolOutputLength = 20_000

    /// The row as Show Tool Output draws it: a tool's output after its
    /// summary, its first `maxShownOutputLines` lines and how many more.
    /// Every other row, and a tool without output, is unchanged.
    public func withToolOutput() -> TranscriptEntry {
        guard case .tool = kind, let shownOutput else { return self }
        var shown = self
        shown.text = text + "\n" + shownOutput
        return shown
    }

    /// The most output lines a row draws. 200 rows of 20,000 characters
    /// took 8.4 seconds to lay out whole, 2.1 at 40 lines, 1.4 at 20 (0.66
    /// without output); a long log is copied whole with Copy Output rather
    /// than read as one row.
    public static let maxShownOutputLines = 20

    /// The output as a row shows it, cut at `maxShownOutputLines` with a
    /// line saying how many more there are.
    public var shownOutput: String? {
        guard let output else { return nil }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > Self.maxShownOutputLines else { return output }
        let more = lines.count - Self.maxShownOutputLines
        return lines.prefix(Self.maxShownOutputLines).joined(separator: "\n")
            + "\n[\(more) more \(more == 1 ? "line" : "lines"). Copy Output copies it all.]"
    }

    /// `text` trimmed, cut at `maxToolOutputLength` with a note saying so;
    /// nil when nothing is left.
    static func keptOutput(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxToolOutputLength else { return trimmed }
        return String(trimmed.prefix(maxToolOutputLength)) + "\n[Output cut at \(maxToolOutputLength.formatted()) characters.]"
    }

    /// The file a tool row read or wrote, if its input names one.
    public var filePath: String? {
        toolInput?["file_path"]?.string ?? toolInput?["notebook_path"]?.string
    }
}

/// What one reduction changed, so the view touches only that row.
public enum TranscriptChange: Sendable, Equatable {
    case inserted(id: String)
    case updated(id: String)
}

/// Folds the CLI's events into transcript rows.
public struct Transcript: Sendable {
    public private(set) var entries: [TranscriptEntry] = []
    public private(set) var diagnostics: [String] = []
    private var indexByID: [String: Int] = [:]
    private var streamingMessageID: String?
    /// Which tool each open permission request is for, so a withdrawn
    /// request can find its row.
    private var toolUseIDByRequestID: [String: String] = [:]
    /// Assistant messages whose text arrived as deltas; their later
    /// `assistant` lines must not add the same text again.
    private var streamedMessageIDs: Set<String> = []
    /// Messages whose thinking arrived as stream events; their later
    /// `assistant` lines must not add the same thinking again.
    private var streamedThinkingMessageIDs: Set<String> = []
    /// Thinking rows still streaming, by content block index in the current
    /// message.
    private var openThinkingIDs: [Int: String] = [:]

    public init() {}

    /// Restores a transcript from saved rows (for example a session read back
    /// with `SessionHistory.loadSession`), so events streamed after a resume
    /// update existing rows and append new ones. A repeated id keeps its
    /// first row and is reported in `diagnostics`.
    public init(restoring savedEntries: [TranscriptEntry]) {
        for entry in savedEntries {
            guard indexByID[entry.id] == nil else {
                diagnostics.append("restored transcript repeats id \(entry.id)")
                continue
            }
            _ = insert(entry)
        }
    }

    public func entry(id: String) -> TranscriptEntry? {
        indexByID[id].map { entries[$0] }
    }

    @discardableResult
    public mutating func appendUser(_ text: String, id: String = UUID().uuidString) -> [TranscriptChange] {
        [insert(TranscriptEntry(id: "user:\(id)", kind: .user, text: text))]
    }

    /// Preserve the row's identity when a failed stdin write means the
    /// prompt was not sent; the pending message can then be retried.
    public mutating func markUserUnsent(id: String) {
        guard let index = indexByID["user:\(id)"], entries[index].kind == .user else { return }
        entries[index].kind = .notice
        entries[index].text = "Message not sent: " + entries[index].text
    }

    /// Rows still waiting on the user when a turn ends: the request can't be
    /// answered any more, and the tool never ran.
    private mutating func settleUnanswered() -> [TranscriptChange] {
        toolUseIDByRequestID = [:]
        var changes: [TranscriptChange] = []
        for index in entries.indices {
            guard case .tool(let name, .awaitingPermission) = entries[index].kind else { continue }
            entries[index].kind = .tool(name: name, status: .failed)
            changes.append(.updated(id: entries[index].id))
        }
        return changes
    }

    /// The user refused the tool. Its row reads denied from now on: the
    /// error result the CLI sends for it doesn't make it a failure.
    @discardableResult
    public mutating func markDenied(toolUseID: String?) -> [TranscriptChange] {
        guard let toolUseID else { return [] }
        let id = "tool:\(toolUseID)"
        guard let index = indexByID[id], case .tool(let name, _) = entries[index].kind else { return [] }
        entries[index].kind = .tool(name: name, status: .denied)
        // The CLI's "The user denied this…" isn't the tool's output: none
        // ran. A restored session applies the result before this.
        entries[index].output = nil
        return [.updated(id: id)]
    }

    /// The user answered the permission request for `toolUseID`. The tool
    /// now runs (if allowed; a denial arrives as an error result), so its
    /// row is running again, with its clock started from now.
    @discardableResult
    public mutating func permissionAnswered(toolUseID: String?, at now: Date = Date()) -> [TranscriptChange] {
        guard let toolUseID else { return [] }
        let id = "tool:\(toolUseID)"
        guard let index = indexByID[id], case .tool(let name, .awaitingPermission) = entries[index].kind else { return [] }
        entries[index].kind = .tool(name: name, status: .running)
        entries[index].startedAt = now
        return [.updated(id: id)]
    }

    /// Folds one event in. `now` is when it arrived, recorded as a new tool
    /// row's `startedAt`; nil when replaying a saved session.
    @discardableResult
    public mutating func apply(_ event: StreamEvent, at now: Date? = Date()) -> [TranscriptChange] {
        switch event {
        case .sessionStarted, .initialized, .usageLimits, .contextUsage, .permissionModeReported, .activity:
            return []

        case .permissionCancelled(let requestID):
            // The prompt is gone; the CLI's result for the tool settles the
            // row, so until then it is no longer waiting on the user.
            guard let toolUseID = toolUseIDByRequestID.removeValue(forKey: requestID) else { return [] }
            return permissionAnswered(toolUseID: toolUseID, at: now ?? Date())

        case .permissionRequest(let request):
            // The tool waits on the user; its row shouldn't say "running".
            guard let toolUseID = request.toolUseID else { return [] }
            toolUseIDByRequestID[request.requestID] = toolUseID
            let id = "tool:\(toolUseID)"
            guard let index = indexByID[id], case .tool(let name, .running) = entries[index].kind else { return [] }
            entries[index].kind = .tool(name: name, status: .awaitingPermission)
            return [.updated(id: id)]

        case .messageStarted(let messageID):
            let changes = finishOpenThinking()
            streamingMessageID = messageID
            return changes

        case .thinkingStarted(let index):
            guard let messageID = streamingMessageID else {
                diagnostics.append("thinking block with no message in progress")
                return []
            }
            let id = Self.thinkingID(messageID: messageID, index: index)
            guard indexByID[id] == nil else {
                diagnostics.append("thinking block \(id) started twice")
                return []
            }
            streamedThinkingMessageIDs.insert(messageID)
            openThinkingIDs[index] = id
            return [insert(TranscriptEntry(id: id, kind: .thinking(isFinished: false), text: ""))]

        case .thinkingDelta(let index, let text):
            guard let id = openThinkingIDs[index], let row = indexByID[id] else {
                diagnostics.append("thinking delta with no thinking block in progress")
                return []
            }
            guard !text.isEmpty else { return [] }
            entries[row].text += text
            return [.updated(id: id)]

        case .contentBlockFinished(let index):
            guard let id = openThinkingIDs.removeValue(forKey: index) else { return [] }
            return finishThinking(id: id)

        case .textDelta(let messageID, let text):
            guard let messageID = messageID ?? streamingMessageID else {
                diagnostics.append("text delta with no message in progress")
                return []
            }
            streamedMessageIDs.insert(messageID)
            return appendAssistantText(text, messageID: messageID)

        case .assistantMessage(let messageID, let blocks):
            var changes: [TranscriptChange] = []
            for block in blocks {
                switch block {
                case .text(let text) where !streamedMessageIDs.contains(messageID):
                    changes += appendAssistantText(text, messageID: messageID)
                case .thinking(let text) where !streamedThinkingMessageIDs.contains(messageID):
                    var index = 0
                    while indexByID[Self.thinkingID(messageID: messageID, index: index)] != nil { index += 1 }
                    changes.append(insert(TranscriptEntry(
                        id: Self.thinkingID(messageID: messageID, index: index),
                        kind: .thinking(isFinished: true),
                        text: Self.finishedThinkingText(text)
                    )))
                case .toolUse(let toolID, let name, let input) where indexByID["tool:\(toolID)"] == nil:
                    changes.append(insert(TranscriptEntry(
                        id: "tool:\(toolID)",
                        kind: .tool(name: name, status: .running),
                        text: ToolSummary.describe(name: name, input: input),
                        toolInput: input,
                        startedAt: now
                    )))
                default:
                    break
                }
            }
            return changes

        case .toolResult(let toolUseID, let text, let isError):
            let id = "tool:\(toolUseID)"
            guard let index = indexByID[id], case .tool(let name, let status) = entries[index].kind,
                  status != .denied else { return [] }
            entries[index].kind = .tool(name: name, status: isError ? .failed : .succeeded)
            entries[index].output = TranscriptEntry.keptOutput(text)
            return [.updated(id: id)]

        case .turnStopped:
            streamingMessageID = nil
            let changes = finishOpenThinking() + settleUnanswered()
            return changes + [insert(TranscriptEntry(id: "notice:\(UUID().uuidString)", kind: .notice, text: "Stopped."))]

        case .turnFinished(let isError, let summary):
            streamingMessageID = nil
            let changes = finishOpenThinking() + settleUnanswered()
            guard isError else { return changes }
            return changes + [insert(TranscriptEntry(
                id: "notice:\(UUID().uuidString)",
                kind: .notice,
                text: summary.map { "Error: \($0)" } ?? "The turn ended with an error."
            ))]

        case .processExited(let status):
            // Nothing will finish what was underway: a running tool reads
            // failed, as a saved session shows one with no result.
            streamingMessageID = nil
            var changes = finishOpenThinking() + settleUnanswered()
            for index in entries.indices {
                guard case .tool(let name, .running) = entries[index].kind else { continue }
                entries[index].kind = .tool(name: name, status: .failed)
                changes.append(.updated(id: entries[index].id))
            }
            guard status != 0 else { return changes }
            return changes + [insert(TranscriptEntry(
                id: "notice:\(UUID().uuidString)", kind: .notice, text: "Claude exited with status \(status)."
            ))]

        case .unrecognized(let type, _):
            diagnostics.append("unrecognized stream line: \(type)")
            return []
        }
    }

    private mutating func appendAssistantText(_ text: String, messageID: String) -> [TranscriptChange] {
        let id = "assistant:\(messageID)"
        if let index = indexByID[id] {
            entries[index].text += text
            return [.updated(id: id)]
        }
        // An assistant message that is only a tool call never gets a text row.
        guard !text.isEmpty else { return [] }
        return [insert(TranscriptEntry(id: id, kind: .assistant, text: text))]
    }

    private static func thinkingID(messageID: String, index: Int) -> String {
        "thinking:\(messageID):\(index)"
    }

    /// Thinking text as a finished row shows it: trimmed, or the placeholder
    /// when the CLI sent none.
    private static func finishedThinkingText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? TranscriptEntry.thinkingPlaceholder : trimmed
    }

    private mutating func finishThinking(id: String) -> [TranscriptChange] {
        guard let row = indexByID[id] else { return [] }
        entries[row].kind = .thinking(isFinished: true)
        entries[row].text = Self.finishedThinkingText(entries[row].text)
        return [.updated(id: id)]
    }

    /// Closes thinking rows whose block never reported its end (an
    /// interrupted turn), so none stays "thinking" forever.
    private mutating func finishOpenThinking() -> [TranscriptChange] {
        let ids = openThinkingIDs.sorted { $0.key < $1.key }.map(\.value)
        openThinkingIDs = [:]
        return ids.flatMap { finishThinking(id: $0) }
    }

    private mutating func insert(_ entry: TranscriptEntry) -> TranscriptChange {
        indexByID[entry.id] = entries.count
        entries.append(entry)
        return .inserted(id: entry.id)
    }
}
