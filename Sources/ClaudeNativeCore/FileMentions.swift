import Foundation

/// The message field's @ file picker. Choosing a file puts its path in the
/// message as "@path"; Claude opens it with its Read tool. The CLI doesn't
/// read the file itself in stream-json mode (tested: with tools off, Claude
/// couldn't see an @-mentioned file; with Read allowed it read it).
public enum FileMentionSearch {
    /// How many files the list shows; a longer query narrows it.
    public static let maxListed = 50

    /// The text after "@" while a mention is being typed at the end of the
    /// draft: the "@" starts the draft or follows whitespace, and nothing
    /// after it is whitespace. Nil otherwise, so "me@example" isn't one.
    public static func query(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let rest = draft[draft.index(after: at)...]
        guard !rest.contains(where: \.isWhitespace) else { return nil }
        return String(rest)
    }

    /// `draft` with an "@" added to start a mention, after a space when the
    /// draft ends mid-word, so the text already typed stays.
    public static func starting(in draft: String) -> String {
        guard let last = draft.last, !last.isWhitespace else { return draft + "@" }
        return draft + " @"
    }

    /// `draft` with the mention being typed replaced by `path`, quoted when
    /// it holds a space, and a space after it to go on typing.
    public static func completed(_ draft: String, with path: String) -> String {
        guard query(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<at]) + mention(path) + " "
    }

    /// `draft` with a mention of each file added at the end, as dropping
    /// files on the conversation does: paths inside `root` relative to it,
    /// others in full, so Claude can still read them.
    public static func mentioning(_ files: [URL], under root: URL?, in draft: String) -> String {
        guard !files.isEmpty else { return draft }
        let mentions = files.map { file in
            mention(root.map { ProjectFiles.relativePath(file, base: $0.standardizedFileURL.path) } ?? file.standardizedFileURL.path)
        }
        let gap = draft.last.map { $0.isWhitespace ? "" : " " } ?? ""
        return draft + gap + mentions.joined(separator: " ") + " "
    }

    /// "@path", quoted when the path holds a space.
    private static func mention(_ path: String) -> String {
        path.contains(where: \.isWhitespace) ? "@\"\(path)\"" : "@\(path)"
    }

    /// Paths under `root`, relative to it, for `query`: files whose name
    /// starts with it first, then any whose path contains it, shorter paths
    /// first in each. An empty query lists the folder's own files.
    public static func matches(_ query: String, under root: URL) -> [String] {
        let base = root.standardizedFileURL.path
        let entries = query.isEmpty
            ? ProjectFiles.children(of: root).filter { !$0.isFolder }
            : ProjectFiles.matches(query, under: root)
        let needle = query.lowercased()
        let starts = entries.filter { !needle.isEmpty && $0.name.lowercased().hasPrefix(needle) }
        let rest = entries.filter { !starts.contains($0) }
        return (starts + rest).prefix(maxListed).map { ProjectFiles.relativePath($0.url, base: base) }
    }

    /// What VoiceOver hears for a file in the list: its name, then the
    /// folder it's in, so the name comes first.
    public static func spoken(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return "\(path[path.index(after: slash)...]), in \(path[..<slash])"
    }

    /// How many files match, said when the list first appears.
    public static func countWording(_ count: Int) -> String {
        switch count {
        case 0: "No files match."
        case 1: "1 file."
        default: "\(count) files."
        }
    }
}
