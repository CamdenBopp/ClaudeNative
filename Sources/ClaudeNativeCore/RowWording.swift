import Foundation

/// The words a transcript row shows and speaks. VoiceOver reads a row as its
/// accessibility value, so this is what a VoiceOver user hears for each
/// message, kept here so tests can pin it.
public enum RowWording {
    /// The title VoiceOver speaks before a row's text: "You", "Claude",
    /// "Notice", "Thinking" or "Thought", or "Tool, running/done/failed".
    /// A running tool given `runningSeconds` (see `runningSeconds(of:at:)`)
    /// says how long it has run: "Tool, running 40 seconds".
    public static func spokenTitle(of entry: TranscriptEntry, runningSeconds: Int? = nil) -> String {
        switch entry.kind {
        case .user: "You"
        case .assistant: "Claude"
        case .notice: "Notice"
        case .thinking(let isFinished): isFinished ? "Thought" : "Thinking"
        case .tool(let name, let status):
            switch status {
            case .awaitingPermission:
                name == AskUserQuestion.toolName ? "Tool, waiting for your answer" : "Tool, waiting for permission"
            case .running:
                if let runningSeconds, runningSeconds > 0 {
                    "Tool, running \(ElapsedWording.spoken(runningSeconds))"
                } else {
                    "Tool, running"
                }
            case .succeeded: "Tool, done"
            case .failed: "Tool, failed"
            case .denied: "Tool, denied"
            }
        }
    }

    /// The spoken title with ", marked" when the user marked the row. A
    /// Claude reply is a group of its blocks, and this is the group's name:
    /// "Claude" or "Claude, marked".
    public static func spokenTitle(of entry: TranscriptEntry, isMarked: Bool, runningSeconds: Int? = nil) -> String {
        let plainTitle = spokenTitle(of: entry, runningSeconds: runningSeconds)
        return isMarked ? "\(plainTitle), marked" : plainTitle
    }

    /// A row's body text. Tool rows drop the working folder from paths;
    /// a thinking row with only the CLI's placeholder has none, since the
    /// placeholder would repeat the title.
    public static func text(of entry: TranscriptEntry, base: URL?) -> String {
        switch entry.kind {
        case .user, .assistant, .notice:
            entry.text
        case .thinking:
            entry.text == TranscriptEntry.thinkingPlaceholder ? "" : entry.text
        case .tool:
            ToolSummary.shorten(entry.text, relativeTo: base)
        }
    }

    /// What a row writes as its title. A tool row writes its status alone,
    /// since the card already reads as a tool call; VoiceOver still hears
    /// "Tool, done". Other rows write their spoken title. A running tool
    /// given `runningSeconds` writes how long it has run: "Running  ·  40s".
    public static func visibleTitle(of entry: TranscriptEntry, runningSeconds: Int? = nil) -> String {
        guard case .tool(_, let status) = entry.kind else { return spokenTitle(of: entry) }
        return switch status {
        case .awaitingPermission: "Waiting for you"
        case .running:
            if let runningSeconds, runningSeconds > 0 {
                "Running\(titleSeparator)\(ElapsedWording.visible(runningSeconds))"
            } else {
                "Running"
            }
        case .succeeded: "Done"
        case .failed: "Failed"
        case .denied: "Denied"
        }
    }

    /// What a row's title puts between its parts: "Running  ·  40s",
    /// "Claude  ·  Marked".
    public static let titleSeparator = "  ·  "

    /// How long a running tool row has run as of `now`, in the steps
    /// `ElapsedWording.shownSeconds` gives; nil for any other row, or a
    /// running one whose start this app never saw.
    public static func runningSeconds(of entry: TranscriptEntry, at now: Date) -> Int? {
        guard case .tool(_, .running) = entry.kind, let startedAt = entry.startedAt else { return nil }
        return ElapsedWording.shownSeconds(now.timeIntervalSince(startedAt))
    }

    /// What VoiceOver says for a row: "title: text", or the title alone when
    /// there is no text. A marked row's title gains ", marked".
    ///
    /// `renderedText` is a Claude reply's text as drawn, without Markdown
    /// syntax. When given it replaces the row's text and is always spoken
    /// after a colon, even when empty.
    public static func accessibilityValue(
        for entry: TranscriptEntry, base: URL?, isMarked: Bool, renderedText: String? = nil,
        runningSeconds: Int? = nil
    ) -> String {
        let title = spokenTitle(of: entry, isMarked: isMarked, runningSeconds: runningSeconds)
        if let renderedText { return "\(title): \(renderedText)" }
        let text = text(of: entry, base: base)
        return text.isEmpty ? title : "\(title): \(text)"
    }
}

/// Everything a row's spoken value is built from. A row keeps one and
/// changes a single part at a time (a final Markdown parse, a mark), so the
/// value is always rebuilt from all of them and no path can drop the mark.
public struct RowSpeech: Sendable, Equatable {
    public var entry: TranscriptEntry
    public var base: URL?
    public var isMarked: Bool
    /// A Claude reply's text as drawn; nil for rows shown as plain text.
    public var renderedText: String?
    /// How long a running tool has run, from `RowWording.runningSeconds`.
    public var runningSeconds: Int?

    /// Whether the row's title changed from `old`: marked or unmarked, a
    /// tool's status, thinking becoming a thought. VoiceOver keeps reading a
    /// focused element's old value until told, so these changes are posted.
    /// Text streaming in and a running tool's clock are not: VoiceOver
    /// would start reading the row again on every update.
    public func titleChanged(from old: RowSpeech?) -> Bool {
        guard let old else { return false }
        return old.isMarked != isMarked || old.entry.kind != entry.kind
    }

    public init(
        entry: TranscriptEntry, base: URL?, isMarked: Bool, renderedText: String? = nil, runningSeconds: Int? = nil
    ) {
        self.entry = entry
        self.base = base
        self.isMarked = isMarked
        self.renderedText = renderedText
        self.runningSeconds = runningSeconds
    }

    /// The row's title, marked or not: what a reply's group is named.
    public var title: String {
        RowWording.spokenTitle(of: entry, isMarked: isMarked, runningSeconds: runningSeconds)
    }

    /// What VoiceOver says for the row.
    public var value: String {
        RowWording.accessibilityValue(
            for: entry, base: base, isMarked: isMarked, renderedText: renderedText, runningSeconds: runningSeconds)
    }
}
