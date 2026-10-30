import Foundation

/// The files panel's view of a folder: one level at a time for the tree,
/// and a capped walk for the filter. Hidden files and the folders tools
/// fill (version control, build output, dependencies) are left out.
public enum ProjectFiles {
    public struct Entry: Sendable, Hashable, Identifiable {
        public let url: URL
        public let isFolder: Bool
        public var id: URL { url }
        public var name: String { url.lastPathComponent }
    }

    /// Folders whose contents nobody browses by hand.
    static let skippedFolders: Set<String> = [".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm", "Pods"]

    /// How many matches the filter lists; more is what a longer filter is for.
    public static let maxMatches = 200
    /// How many entries the filter walks before giving up on a huge tree.
    static let maxWalked = 50_000

    /// A folder's entries, folders first, then by name as Finder sorts.
    public static func children(of folder: URL) -> [Entry] {
        // Listed through a link it lists nothing, so the link is followed.
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url -> Entry? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // A link to a folder is a folder, as in Finder.
            let isFolder = values?.isSymbolicLink == true
                ? (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                : values?.isDirectory ?? false
            if isFolder, skippedFolders.contains(url.lastPathComponent) { return nil }
            return Entry(url: url, isFolder: isFolder)
        }
        .sorted { left, right in
            left.isFolder != right.isFolder
                ? left.isFolder
                : left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// Files under `root` whose path, relative to it, contains every word
    /// of `query` (case and accents aside), shortest paths first.
    public static func matches(_ query: String, under root: URL) -> [Entry] {
        search(query, under: root).entries
    }

    /// The first `maxMatches` matches, and how many there were in all.
    public struct Search: Sendable {
        public let entries: [Entry]
        public let total: Int
    }

    public static func search(_ query: String, under folder: URL) -> Search {
        // Through a link to the project folder: the walk doesn't follow
        // one, so a linked project's filter found nothing.
        let root = folder.resolvingSymlinksInPath()
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return Search(entries: [], total: 0) }
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return Search(entries: [], total: 0) }
        var found: [Entry] = []
        var walked = 0
        let base = root.standardizedFileURL.path
        while let url = walker.nextObject() as? URL, walked < maxWalked {
            walked += 1
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder {
                if skippedFolders.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            let path = relativePath(url, base: base)
            if words.allSatisfy({ path.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                found.append(Entry(url: url, isFolder: false))
            }
        }
        let sorted = found.sorted { relativePath($0.url, base: base).count < relativePath($1.url, base: base).count }
        return Search(entries: Array(sorted.prefix(maxMatches)), total: found.count)
    }

    /// What VoiceOver hears once a filter's results are in.
    public static func spokenCount(shown: Int, total: Int) -> String {
        if total > shown { return "\(total) files, the first \(shown) shown." }
        return total == 1 ? "1 file." : "\(total) files."
    }

    /// `url`'s path under `base`, without the leading slash; its full path
    /// when it isn't under `base` (a sibling "apple" isn't under "app").
    public static func relativePath(_ url: URL, base: String) -> String {
        let path = url.standardizedFileURL.path
        let folder = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(folder) else { return path }
        return String(path.dropFirst(folder.count))
    }
}
