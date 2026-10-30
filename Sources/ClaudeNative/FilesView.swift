import ClaudeNativeCore
import SwiftUI

/// The side panel's Files: the folder as a tree, folders first, with a
/// filter field above it ("Filter files", as the Claude app words it).
/// Return or a double-click opens a file in the editor; a folder opens and
/// closes with the arrow keys, as in any outline.
struct FilesView: View {
    let folder: URL?
    /// Bumped by F6 to move focus back into the tree.
    var focusToken = 0
    /// Starts with the keyboard in the filter field, for Go to File.
    var startsInFilter = false
    let openFile: (URL) -> Void
    @State private var query = ""
    @State private var selection: URL?
    @State private var matches: [ProjectFiles.Entry] = []
    /// The filter and folder `matches` were found for; until they're the
    /// current ones the search is still running.
    @State private var matchedFor: SearchKey?
    @FocusState private var treeFocused: Bool
    @FocusState private var filterFocused: Bool
    /// Something was typed in the filter. A tree brought back by clearing
    /// it then leaves the keyboard where it is; F6 still moves in.
    @State private var filterUsed = false

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter files", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter files")
                .focused($filterFocused)
                // As Go to File works elsewhere: Return opens the highlighted
                // match (the first, until one is chosen), and Down Arrow
                // moves into the list. Both did nothing; only Tab reached it.
                .onSubmit {
                    guard ConversationSearch.isActive(query), let url = openingMatch else { return }
                    open([url])
                }
                .onKeyPress(.downArrow) {
                    guard ConversationSearch.isActive(query), let match = openingMatch else { return .ignored }
                    selection = match
                    treeFocused = true
                    return .handled
                }
                .padding(Theme.Spacing.small)
            if folder == nil {
                EmptyState("No Folder", systemImage: "folder", description: "Choose a folder to see its files.")
                    .frame(maxHeight: .infinity)
            } else if ConversationSearch.isActive(query) {
                if matchedFor != searchKey {
                    // Not "No Matches" before the search has looked.
                    ProgressView("Searching…")
                        .frame(maxHeight: .infinity)
                } else if matches.isEmpty {
                    EmptyState("No Matches", systemImage: "magnifyingglass", description: "No file's path has \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}.")
                        .frame(maxHeight: .infinity)
                } else {
                    List(matches, selection: $selection) { entry in
                        Text(relative(entry.url))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .tag(entry.url)
                    }
                    .listStyle(.inset)
                    .focused($treeFocused)
                    .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { open($0) }
                }
            } else if let folder {
                // Not once the filter's been typed in: clearing it brings
                // the tree back, whose load took focus from the field
                // still being edited.
                FileTreeOutline(root: folder, focusToken: focusToken, takesFocus: !startsInFilter && !filterUsed, openFile: openFile)
            }
        }
        // Once typing pauses, as the slash list's count waits: earlier,
        // VoiceOver's echo of the typing drowned the count (live). The walk
        // runs off the main thread; a newer query cancels it.
        // Searched again when the window's folder changes, too.
        .task(id: searchKey) {
            guard let folder, ConversationSearch.isActive(query) else { matches = []; matchedFor = nil; return }
            guard (try? await Task.sleep(for: SlashCommandSearch.announcementDelay)) != nil else { return }
            let key = searchKey
            let found = await Task.detached { ProjectFiles.search(key.query, under: folder) }.value
            guard !Task.isCancelled else { return }
            matches = found.entries
            matchedFor = key
            // The whole count: past the cap it said "200 files" for thousands.
            Announcer.announce(ProjectFiles.spokenCount(shown: found.entries.count, total: found.total), urgency: .urgent)
        }
        .onChange(of: query) { if ConversationSearch.isActive(query) { filterUsed = true } }
        .onChange(of: searchKey) { selection = nil }
        .onChange(of: focusToken) { treeFocused = true }
        .onAppear { if startsInFilter { filterFocused = true } }
    }

    struct SearchKey: Equatable {
        let query: String
        let folder: URL?
    }

    private var searchKey: SearchKey { SearchKey(query: query, folder: folder) }

    private var openingMatch: URL? {
        Self.openingMatch(selection: selection, matches: matches.map(\.url), matchedFor: matchedFor, current: searchKey)
    }

    static func openingMatch(selection: URL?, matches: [URL], matchedFor: SearchKey?, current: SearchKey) -> URL? {
        guard matchedFor == current else { return nil }
        if let selection, matches.contains(selection) { return selection }
        return matches.first
    }

    private func relative(_ url: URL) -> String {
        guard let folder else { return url.path }
        // The search walks the folder a link points to, so matches are
        // under that path.
        return ProjectFiles.relativePath(url, base: folder.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    private func open(_ urls: Set<URL>) {
        guard let url = urls.first else { return }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return }
        openFile(url)
    }
}
