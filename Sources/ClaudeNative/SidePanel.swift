import ClaudeNativeCore
import Observation
import SwiftUI

enum SidePanelLayout {
    static let minWidth: CGFloat = 320
    static let idealWidth: CGFloat = 520
    static let maxWidth: CGFloat = 900
    /// Between a changed file's path and its summary line, so the two read
    /// as one item.
    static let fileLineSpacing: CGFloat = 2
    /// How long the panel takes to slide in. A field focused before then
    /// takes the keyboard, but VoiceOver's cursor stayed where it was:
    /// the field wasn't in its view yet.
    static let appearanceDuration: Duration = .milliseconds(350)
}

/// What the side panel beside the conversation shows: one file or one set
/// of changes at a time, with a back list instead of tabs (fewer stops for
/// VoiceOver, less chrome on screen).
@MainActor
@Observable
final class SidePanel {
    enum Item: Equatable {
        case file(URL)
        case changes(FileDiff)
        /// Every uncommitted change in the project, as a list of files.
        case projectChanges
        /// The folder's files, as a tree.
        case files
        /// A shell in the folder.
        case terminal
        /// A quick question in a session of its own.
        case sideChat

        var title: String {
            switch self {
            case .file(let url): url.lastPathComponent
            case .changes(let diff): "Changes to \(URL(fileURLWithPath: diff.path).lastPathComponent)"
            case .projectChanges: "Uncommitted Changes"
            case .files: "Files"
            case .terminal: "Terminal"
            case .sideChat: "Side Chat"
            }
        }

        /// The panel's close button, named for what it closes: "Close
        /// Editor" read as the code editor even over a side chat.
        var closeTitle: String {
            switch self {
            case .file, .changes: "Close Editor"
            case .projectChanges: "Close Changes"
            case .files: "Close Files"
            case .terminal: "Close Terminal"
            case .sideChat: "Close Side Chat"
            }
        }
    }

    var isShown = false
    private(set) var current: Item?
    /// The window's shell, kept while the panel shows other things.
    let terminal = TerminalModel()
    /// The window's side chat, a session apart from the main one.
    let sideChat = SidePanel.makeSideChat()

    static func makeSideChat(cliExecutable: URL? = nil) -> AppModel {
        let chat = AppModel(cliExecutable: cliExecutable)
        chat.declinesPermissions = true
        return chat
    }
    private(set) var back: [Item] = []
    /// Open documents by file, so unsaved edits survive going back and forth.
    private var documents: [URL: EditorDocument] = [:]
    /// Documents with edits not yet saved, for closing the window to ask about.
    var unsavedDocuments: [EditorDocument] { documents.values.filter(\.isDirty).sorted { $0.title < $1.title } }
    /// Whether the item on screen was opened by the user and should take
    /// keyboard focus.
    private(set) var focusRequest = 0
    /// Bumped to move keyboard focus into the open editor, diff or changes
    /// list without rebuilding it (undo history, caret and scroll stay).
    private(set) var editorFocusToken = 0

    /// Whether Files opens with the keyboard in its filter (Go to File)
    /// rather than in the tree.
    private(set) var filesStartInFilter = false

    /// Command-P, as the Claude app goes to a file: Files, typing into its
    /// filter.
    func goToFile() {
        open(.files)
        filesStartInFilter = true
    }

    func open(_ item: Item, focus: Bool = true) {
        filesStartInFilter = false
        if let current, current != item { back.append(current) }
        current = item
        isShown = true
        if focus { focusRequest += 1 }
        Announcer.announce(item.announcement)
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        current = previous
        Announcer.announce(previous.announcement)
    }

    func close() {
        isShown = false
        isExpanded = false
    }

    /// Shift-Command-Backslash, as the Claude app expands a pane: the panel
    /// fills the window's detail area, for reading a file or a diff at a
    /// large text size, and goes back beside the session the same way.
    private(set) var isExpanded = false

    func toggleExpanded() {
        guard isShown else { return }
        isExpanded.toggle()
        editorFocusToken += 1
        Announcer.announce(isExpanded ? "Panel expanded." : "Panel back beside the session.")
    }

    /// Bumped when files may have changed, so the changes list reloads.
    private(set) var changesRefreshToken = 0

    func refreshChanges() {
        changesRefreshToken += 1
    }

    func focusEditor() {
        isShown = true
        editorFocusToken += 1
    }

    /// Open in New Window: the file moves to its own window, its unsaved
    /// edits with it. The window used to read the file from disk, leaving
    /// the edits stranded here, and saving one copy set the other against it.
    func handOff(_ url: URL) -> EditorDocument? {
        let document = documents.removeValue(forKey: url)
        back.removeAll { $0 == .file(url) }
        if current == .file(url) {
            current = back.popLast()
            if current == nil { close() }
        }
        return document
    }

    func document(for url: URL) -> EditorDocument {
        if let document = documents[url] { return document }
        let document = EditorDocument(url: url)
        documents[url] = document
        return document
    }

    /// Re-reads open files that Claude may have changed.
    func checkDisk() {
        documents.values.forEach { $0.checkDisk() }
    }
}

private extension SidePanel.Item {
    var announcement: String {
        switch self {
        case .file(let url): "Opened \(url.lastPathComponent) in the editor."
        case .changes(let diff): "Showing changes to \(URL(fileURLWithPath: diff.path).lastPathComponent)."
        case .projectChanges: "Showing uncommitted changes."
        case .files: "Showing files."
        case .terminal: "Terminal."
        case .sideChat: "Side chat."
        }
    }
}

/// The side panel's contents: a bar with Back, the title and actions, then
/// the editor or the diff reader.
struct SidePanelView: View {
    let panel: SidePanel
    let base: URL?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.small) {
                Button("Back", systemImage: "chevron.backward", action: panel.goBack)
                    .labelStyle(.iconTarget(.leading))
                    .disabled(panel.back.isEmpty)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back")
                Text(panel.current?.title ?? "Editor")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if case .file(let url)? = panel.current {
                    SaveButton(document: panel.document(for: url))
                        .labelStyle(.iconTarget)
                        .help("Save (Command-S)")
                    Button("Open in New Window", systemImage: "macwindow") {
                        EditorHandoff.pending[url] = panel.handOff(url)
                        openWindow(value: url)
                    }
                        .labelStyle(.iconTarget)
                        .help("Open in New Window")
                }
                Button(panel.current?.closeTitle ?? "Close Panel", systemImage: "xmark", action: panel.close)
                    .labelStyle(.iconTarget(.trailing))
                    .help("\(panel.current?.closeTitle ?? "Close Panel") (Command-Backslash)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            Divider()
            switch panel.current {
            case .file(let url)?:
                EditorPane(document: panel.document(for: url), takesFocus: true, focusToken: panel.editorFocusToken, savesFromToolbar: false)
                    .id(PanelIdentity(url: url, request: panel.focusRequest))
            case .changes(let diff)?:
                DiffReaderView(diff: diff, base: base, takesFocus: true, focusToken: panel.editorFocusToken)
                    .id(panel.focusRequest)
            case .projectChanges?:
                ProjectChangesView(folder: base, refreshToken: panel.changesRefreshToken, focusToken: panel.editorFocusToken) { diff in
                    panel.open(.changes(diff))
                }
                .id(panel.focusRequest)
            case .files?:
                FilesView(folder: base, focusToken: panel.editorFocusToken, startsInFilter: panel.filesStartInFilter) { url in
                    panel.open(.file(url))
                }
                .id(panel.focusRequest)
            case .terminal?:
                TerminalPanelView(terminal: panel.terminal, folder: base, focusToken: panel.editorFocusToken, openRequest: panel.focusRequest)
            case .sideChat?:
                SideChatView(chat: panel.sideChat, folder: base, focusToken: panel.editorFocusToken, openRequest: panel.focusRequest)
            case nil:
                EmptyState("No File Open", systemImage: "doc.text", description: "Open a file, or choose Show Changes on a tool row.")
                    // Fills the panel, so the bar stays at the top; sized to
                    // itself, it and the bar were centered together.
                    .frame(maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor")
    }

    private struct PanelIdentity: Hashable {
        let url: URL
        let request: Int
    }
}

/// The project's uncommitted changes: a summary heading, then one button per
/// file that reads its status and size ("Modified, Sources/App.swift, 4 lines
/// added, 1 removed") and opens its diff.
struct ProjectChangesView: View {
    let folder: URL?
    let refreshToken: Int
    /// Bumped by F6 to move focus back into the list.
    var focusToken = 0
    let openDiff: (FileDiff) -> Void
    @State private var state: LoadState = .loading
    @AccessibilityFocusState private var summaryFocused: Bool
    @FocusState private var listFocused: Bool
    /// Each open of the list builds a new view (the panel keys it by its
    /// focus request), so this resets exactly when the user asks for it.
    @State private var hasTakenFocus = false
    /// Set by the load that should move VoiceOver; the heading acts on it
    /// once it exists.
    @State private var wantsSummaryFocus = false

    enum LoadState {
        case loading
        case loaded(GitChangeSet)
        case failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Reading changes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                EmptyState("Couldn't Read Changes", systemImage: "exclamationmark.triangle", description: message)
                    .frame(maxHeight: .infinity)
            case .loaded(let set):
                // The summary sits above the list, not in a section header:
                // VoiceOver can't take focus to a List header on macOS and
                // lands on the table instead.
                VStack(alignment: .leading, spacing: 0) {
                    Text(set.spokenSummary)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($summaryFocused)
                        .padding([.horizontal, .top])
                        // Focus asked for in the same update that creates
                        // the heading is dropped; ask once it's in the tree.
                        .task(id: wantsSummaryFocus) {
                            guard wantsSummaryFocus else { return }
                            // As in the diff reader: VoiceOver can't be moved
                            // to the heading until it's in the tree. The flag
                            // resets after, since resetting it restarts this
                            // task and would cancel the wait.
                            // VoiceOver only follows into the panel once the
                            // keyboard is there too, as in the diff reader.
                            listFocused = true
                            try? await Task.sleep(for: Theme.accessibilityFocusDelay)
                            summaryFocused = true
                            wantsSummaryFocus = false
                        }
                    List {
                        ForEach(set.files) { file in
                            Button {
                                if let diff = file.diff { openDiff(diff) }
                            } label: {
                                VStack(alignment: .leading, spacing: SidePanelLayout.fileLineSpacing) {
                                    Text(file.path)
                                        .font(.body.monospaced())
                                    Text("\(file.status.label), \(file.changeSummary)")
                                        .font(.callout)
                                        .foregroundStyle(Color(nsColor: Theme.quietLabel))
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(file.diff == nil)
                            .accessibilityLabel(file.spoken)
                        }
                    }
                    // The heading above sits on the window; the list's own
                    // white fill split the panel into two bands.
                    .scrollContentBackground(.hidden)
                    // Named: VoiceOver said only "table".
                    .accessibilityLabel("Changed files")
                    .focused($listFocused)
                }
            }
        }
        .task(id: refreshToken) { await load() }
        .onChange(of: focusToken) {
            switch state {
            case .loaded:
                wantsSummaryFocus = true
            case .loading:
                // The list takes focus as soon as it loads.
                hasTakenFocus = false
                Announcer.announce("Reading changes.")
            case .failed(let message):
                // Otherwise F6 did nothing and said nothing.
                Announcer.announce("Couldn't read changes. \(message)")
            }
        }
    }

    private func load() async {
        guard let folder else {
            state = .failed("Choose a folder first.")
            return
        }
        do {
            state = .loaded(try await GitChanges.load(in: folder))
            // Only the load that follows the user opening the list moves
            // VoiceOver. Reloads after each reply arrive while the user is
            // reading or typing elsewhere, so they leave focus alone.
            if !hasTakenFocus {
                hasTakenFocus = true
                wantsSummaryFocus = true
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
