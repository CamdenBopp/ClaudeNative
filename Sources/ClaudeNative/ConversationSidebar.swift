import AppKit
import ClaudeNativeCore
import SwiftUI

/// Every project's saved conversations, as the Claude app's Code sidebar
/// shows them. Reads the model here, not in ChatView, so a refreshed list
/// re-runs this body alone.
struct ConversationList: View {
    let model: AppModel
    /// Opens a conversation, or starts one when it's nil, in a folder.
    let open: (URL, SessionHistory.SessionSummary?) -> Void
    /// The toolbar's New Conversation, in the window's own folder.
    let newConversation: () -> Void
    /// Goes up by one each time Command-F asks for the search field.
    var searchRequest = 0
    var sessionActions: SessionActions? = nil

    var body: some View {
        SavedConversationList(
            projects: model.projects,
            selectedID: model.sessionID,
            resume: { project, session in
                guard session.id != model.sessionID else { return }
                open(SavedConversationList.folder(for: session, in: project), session)
            },
            startNew: { project in open(project.directory, nil) },
            newConversation: newConversation,
            working: WorkingConversations.shared.ids,
            waiting: WorkingConversations.shared.waiting,
            unread: WorkingConversations.shared.unread,
            rename: { session, title in
                do {
                    try SessionHistory.rename(session, to: title)
                    model.refreshSessions()
                    Announcer.announceAfterFocusMove("Renamed.")
                } catch {
                    // The sheet is closing, as with "Renamed.", so it waits too.
                    Announcer.announceAfterFocusMove(SessionHistory.ChangeError.renameFailureWording(error), urgency: .urgent)
                }
            },
            delete: { session in
                Task {
                    // A CLI with this conversation would write its file again,
                    // so every one must be gone first: this window's, any
                    // other's, and any still exiting.
                    guard await AppModel.release(session.id, from: model, startNewHere: newConversation) else { return }
                    defer { AppModel.finishedDeleting(session.id) }
                    do {
                        try SessionHistory.delete(session)
                        model.refreshSessions()
                        Announcer.announceAfterFocusMove("Moved to the Trash.")
                    } catch {
                        Announcer.announce("Couldn't delete the session.", urgency: .urgent)
                    }
                }
            },
            searchRequest: searchRequest,
            sessionActions: sessionActions,
            // A sheet waiting on an answer holds the window: Command-2
            // behind the permission sheet opened another session and
            // dropped the request unanswered.
            jumpsAllowed: model.pendingPermission == nil && model.pendingQuestions == nil
        )
    }
}

/// The list itself, apart from the model so a test can host it with saved
/// projects. One section per project, headed by its name as a heading
/// (VoiceOver's heading keys jump between projects) with a button to start
/// a conversation there; the section folds away and stays folded. Each row
/// is one element that reads its title and when it was last used.
struct SavedConversationList: View {
    let projects: [SessionHistory.ProjectSummary]
    let selectedID: String?
    let resume: (SessionHistory.ProjectSummary, SessionHistory.SessionSummary) -> Void
    let startNew: (SessionHistory.ProjectSummary) -> Void
    /// The toolbar's New Conversation, in the window's own folder.
    var newConversation: () -> Void = {}
    /// Conversations working in any window, marked with a dot.
    var working: Set<String> = []
    /// Conversations waiting on the user, and ones that finished unseen,
    /// marked with the accent dot, as in the Claude app.
    var waiting: Set<String> = []
    var unread: Set<String> = []
    /// Whether a selection change waits before opening: it does when made
    /// from the keyboard, so arrowing past rows doesn't open each one.
    var opensAfterPause: () -> Bool = { NSApp.currentEvent?.type == .keyDown }
    var rename: (SessionHistory.SessionSummary, String) -> Void = { _, _ in }
    var delete: (SessionHistory.SessionSummary) -> Void = { _ in }
    /// Goes up by one each time Command-F asks for the search field.
    var searchRequest = 0
    /// The toolbar title's Rename, Pin and Delete, done here.
    var sessionActions: SessionActions? = nil
    /// False while a sheet waits on an answer: Go to Session is off then.
    var jumpsAllowed = true
    /// What's typed in the search field above the list.
    @State private var query = ""
    /// The conversation being renamed.
    @State private var renaming: SessionHistory.SessionSummary?
    /// The conversation waiting for Delete to be confirmed.
    @State private var deleting: SessionHistory.SessionSummary?
    @FocusState private var searchFocused: Bool
    /// The highlighted row, which arrowing moves before anything opens.
    @State private var highlighted: String?
    /// Opens the highlighted row once arrowing pauses.
    @State private var pendingOpen: Task<Void, Never>?
    /// Folded projects, by folder path, one per line.
    @AppStorage("collapsedProjects") private var collapsedStore = ""
    /// Pinned conversations, by id, one per line.
    @AppStorage("pinnedConversations") private var pinnedStore = ""
    /// Archived sessions, by id, one per line: out of the list until Show
    /// Archived Sessions, as the Claude app archives rather than deletes.
    @AppStorage(SessionArchive.defaultsKey) private var archivedStore = ""
    @AppStorage(SessionArchive.showKey) private var showArchived = false
    @Environment(\.openWindow) private var openWindow
    /// Where Go > Next Project and Previous Project arrive: the list's own
    /// unless one is given (a test drives it).
    var projectNavigator: ProjectNavigator? = nil
    @State private var ownNavigator = ProjectNavigator()
    private var navigator: ProjectNavigator { projectNavigator ?? ownNavigator }
    @State private var outline = SidebarOutline()
    /// The project heading Go last moved to.
    @State private var visitedProject: String?
    /// Moves VoiceOver to a project's heading.
    @AccessibilityFocusState private var focusedHeading: String?

    private var pinned: Set<String> { Set(pinnedStore.split(separator: "\n").map(String.init)) }

    private var archived: Set<String> { SessionArchive.ids(in: archivedStore) }

    /// View > Group Sessions By: by folder, or by date as the Claude app
    /// can.
    @AppStorage(SidebarGrouping.defaultsKey) private var grouping = SidebarGrouping.folder

    /// The projects with a Pinned section first, as in the Claude app,
    /// regrouped by date when asked.
    private var arranged: [SessionHistory.ProjectSummary] {
        let shown = SideChats.hiding(projects, ids: showArchived ? sideChatIDs : sideChatIDs.union(archived))
        let pinnedFirst = SessionHistory.pinning(shown, pinned: pinned)
        return grouping == .date ? SessionHistory.byDate(pinnedFirst) : pinnedFirst
    }

    /// Side chats' sessions, by id, one per line: left out of the list, as
    /// the Claude app hides side chats unless asked to show them.
    @AppStorage(SideChats.defaultsKey) private var sideChatStore = ""
    private var sideChatIDs: Set<String> { Set(sideChatStore.split(separator: "\n").map(String.init)) }

    /// One session's row: its title and dot, read as one text, with the
    /// same items as a context menu and as VoiceOver actions
    /// (VO-Command-Space).
    private func row(_ session: SessionHistory.SessionSummary, in project: SessionHistory.ProjectSummary) -> some View {
        // One line, the title, as in the Claude app. VoiceOver
        // also hears when, which tells apart conversations
        // that started with the same words.
        HStack(spacing: Theme.Spacing.small) {
            Text(session.title)
                .lineLimit(1)
                .truncationMode(.tail)
            if let status = status(of: session) {
                Spacer(minLength: 0)
                // The Claude app's dots: the accent color
                // when it wants you, quiet while it works.
                Circle()
                    .fill(status == .working || status == .archived ? Color(nsColor: Theme.quietLabel) : Color.accentColor)
                    .frame(width: SidebarLayout.workingDotDiameter, height: SidebarLayout.workingDotDiameter)
            }
        }
        .help(session.title)
        // One text, as before the dot: the stack would
        // otherwise read as a group.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(Self.spokenRow(session, status: status(of: session)))
        .tag(session.id)
        // The same items as a context menu and as VoiceOver
        // actions (VO-Command-Space).
        .contextMenu {
            Button(pinned.contains(session.id) ? "Unpin" : "Pin") { setPinned(session, !pinned.contains(session.id)) }
            Button("Rename…") { startRenaming(session) }
            Button(unread.contains(session.id) ? "Mark as Read" : "Mark as Unread") { toggleUnread(session) }
            Button("Open in New Window") { openInNewWindow(project, session) }
            Button(archived.contains(session.id) ? "Unarchive" : "Archive") { setArchived(session, !archived.contains(session.id)) }
            Button("Delete…") { deleting = session }
        }
        .accessibilityAction(named: pinned.contains(session.id) ? "Unpin" : "Pin") {
            setPinned(session, !pinned.contains(session.id))
        }
        .accessibilityAction(named: "Rename") { startRenaming(session) }
        .accessibilityAction(named: "Open in New Window") { openInNewWindow(project, session) }
        .accessibilityAction(named: unread.contains(session.id) ? "Mark as Read" : "Mark as Unread") { toggleUnread(session) }
        .accessibilityAction(named: archived.contains(session.id) ? "Unarchive" : "Archive") {
            setArchived(session, !archived.contains(session.id))
        }
        .accessibilityAction(named: "Delete") { deleting = session }
    }

    /// A row's Mark as Unread or Mark as Read, as in the Claude app.
    private func toggleUnread(_ session: SessionHistory.SessionSummary) {
        let isUnread = unread.contains(session.id)
        if isUnread { WorkingConversations.shared.seen(session.id) } else { WorkingConversations.shared.markUnread(session.id) }
        Announcer.announce(isUnread ? "Marked as read." : "Marked as unread.")
    }

    /// A row's Open in New Window, as in the Claude app: a second window
    /// on that session. One already open stays where it is, since two
    /// windows writing one session would interleave it.
    private func openInNewWindow(_ project: SessionHistory.ProjectSummary, _ session: SessionHistory.SessionSummary) {
        guard AppModel.models(showing: session.id).isEmpty else {
            if !AppModel.bringForward(session.id) { Announcer.announce("That session is already open in a window.") }
            return
        }
        NewWindowSession.pending = (Self.folder(for: session, in: project), session)
        openWindow(id: NewWindowSession.windowID)
    }

    private func setArchived(_ session: SessionHistory.SessionSummary, _ archive: Bool) {
        var ids = archived
        if archive { ids.insert(session.id) } else { ids.remove(session.id) }
        archivedStore = ids.sorted().joined(separator: "\n")
        // An archived session leaves Pinned too.
        if archive, pinned.contains(session.id) {
            pinnedStore = pinned.subtracting([session.id]).sorted().joined(separator: "\n")
        }
        Announcer.announce(archive ? "Archived." : "Unarchived.")
    }

    private func setPinned(_ session: SessionHistory.SessionSummary, _ pin: Bool) {
        var ids = pinned
        if pin { ids.insert(session.id) } else { ids.remove(session.id) }
        pinnedStore = ids.sorted().joined(separator: "\n")
        Announcer.announce(pin ? "Pinned." : "Unpinned.")
    }

    /// Projects with the conversations the search matches; while searching,
    /// a project with none is left out.
    /// `folded` without the project holding `sessionID`, so its row shows.
    static func unfolded(_ folded: Set<String>, toShow sessionID: String, in projects: [SessionHistory.ProjectSummary]) -> Set<String> {
        folded.subtracting(projects.filter { $0.sessions.contains { $0.id == sessionID } }.map(\.id))
    }

    /// What Command-1 to 9 open: the first nine rows on screen. They came
    /// from the list without the search, so while searching Command-1
    /// opened a session not shown, and a folded project's match, shown
    /// open by the search, was skipped.
    static func jumpTargets(shown: [SessionHistory.ProjectSummary], folded: Set<String>, searching: Bool) -> [SessionHistory.SessionSummary] {
        // A search opens every project with a match.
        SessionHistory.numbered(shown, folded: searching ? [] : folded)
    }

    private var shownProjects: [SessionHistory.ProjectSummary] {
        guard ConversationSearch.isActive(query) else { return arranged }
        return arranged.compactMap { project in
            let matches = ConversationSearch.filter(project.sessions, query: query)
            return matches.isEmpty ? nil : .init(
                directory: project.directory, name: project.name, sessions: matches,
                startsConversations: project.startsConversations
            )
        }
    }

    static func headingID(_ project: SessionHistory.ProjectSummary) -> String { "heading:" + project.id }

    /// Go > Next Project or Previous Project: from the project Go last
    /// visited, or else the one holding the open conversation, to the
    /// next or previous one, scrolled to and with VoiceOver on its heading.
    /// At either end it stays and says so, as the message moves do.
    private func moveToProject(_ direction: ProjectNavigator.Direction, proxy: ScrollViewProxy) {
        let ids = shownProjects.map(\.id)
        let current = visitedProject.flatMap { ids.firstIndex(of: $0) }
            ?? shownProjects.firstIndex { project in project.sessions.contains { $0.id == (highlighted ?? selectedID) } }
        let target: Int
        switch direction {
        case .next: target = current.map { $0 + 1 } ?? 0
        case .previous: target = current.map { $0 - 1 } ?? ids.count - 1
        }
        guard ids.indices.contains(target) else {
            Announcer.announce(direction == .next ? "Last project." : "First project.")
            return
        }
        let project = shownProjects[target]
        visitedProject = project.id
        if !outline.scrollToHeader(target) {
            proxy.scrollTo(Self.headingID(project), anchor: .top)
        }
        // Asked before the scrolled-to heading is in the accessibility
        // tree, the move is dropped.
        // Cleared first: set while VoiceOver's cursor is on another
        // heading, a heading near the view was sometimes not moved to.
        focusedHeading = nil
        Task {
            try? await Task.sleep(for: Theme.accessibilityFocusDelay)
            focusedHeading = project.id
        }
    }

    private var shownCount: Int { shownProjects.reduce(0) { $0 + $1.sessions.count } }

    private var collapsed: Set<String> { Set(collapsedStore.split(separator: "\n").map(String.init)) }

    /// Open unless folded; a search opens every project with a match.
    private func isExpanded(_ project: SessionHistory.ProjectSummary) -> Binding<Bool> {
        Binding(
            get: { ConversationSearch.isActive(query) || !collapsed.contains(project.id) },
            set: { open in
                var folded = collapsed
                if open { folded.remove(project.id) } else { folded.insert(project.id) }
                collapsedStore = folded.sorted().joined(separator: "\n")
            }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
        List(selection: $highlighted) {
            ForEach(shownProjects) { project in
                Section(isExpanded: isExpanded(project)) {
                    ForEach(project.sessions) { session in
                        row(session, in: project)
                    }
                } header: {
                    HStack {
                        Text(project.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            // Full label color, set apart by weight: over the
                            // translucent sidebar the list's header color
                            // measured 2.8:1 and the quiet label 3.25:1,
                            // while row titles measured 6:1.
                            .foregroundStyle(.primary)
                            .fontWeight(.semibold)
                            .accessibilityAddTraits(.isHeader)
                        // Always shown, as in the Claude app: the sidebar's
                        // own chevron appears only under the pointer.
                        Button(isExpanded(project).wrappedValue ? "Collapse" : "Expand",
                               systemImage: isExpanded(project).wrappedValue ? "chevron.down" : "chevron.right") {
                            isExpanded(project).wrappedValue.toggle()
                        }
                        .labelStyle(.iconTarget(.leading))
                        .buttonStyle(.borderless)
                        .imageScale(.small)
                        .foregroundStyle(Color(nsColor: Theme.quietLabel))
                        .help(isExpanded(project).wrappedValue ? "Collapse" : "Expand")
                        Spacer()
                        if project.startsConversations {
                            Button("New Session in \(project.name)", systemImage: "plus") { startNew(project) }
                                .labelStyle(.iconTarget(.trailing))
                                .buttonStyle(.borderless)
                                .help("New Session in \(project.name)")
                        }
                    }
                    .padding(.trailing, SidebarLayout.headerTrailingInset)
                    .contextMenu {
                        if project.startsConversations {
                            Button("Show in Finder") { Self.showInFinder(project) }
                        }
                    }
                    .id(Self.headingID(project))
                    // A list header row merges into one element whatever
                    // its stack asks, which read "garden, New Conversation in
                    // garden" with no button to press. So it reads the name,
                    // as a heading, and offers the button as an action.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(project.name)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focusedHeading, equals: project.id)
                    .accessibilityActions {
                        Button(isExpanded(project).wrappedValue ? "Collapse" : "Expand") {
                            isExpanded(project).wrappedValue.toggle()
                        }
                        if project.startsConversations {
                            // Listed in reverse: New Session reads first.
                            Button("Show in Finder") { Self.showInFinder(project) }
                            Button("New Session") { startNew(project) }
                        }
                    }
                }
            }
        }
        // A conversation opened from elsewhere (search, a new window) is
        // scrolled into view, so its row is there to see and arrow from.
        .onChange(of: selectedID) { _, id in
            // Go's next project counts from the newly opened conversation.
            visitedProject = nil
            guard let id else { return }
            // Opened from Command-K or Reopen into a folded project, its
            // row wasn't in the list: nothing was selected, and VoiceOver
            // had nothing to arrow from.
            let open = Self.unfolded(collapsed, toShow: id, in: arranged)
            if open != collapsed { collapsedStore = open.sorted().joined(separator: "\n") }
            proxy.scrollTo(id)
        }
        .onAppear {
            if let selectedID { proxy.scrollTo(selectedID) }
        }
        .onChange(of: sessionActions?.request?.count) {
            guard let request = sessionActions?.request,
                  let session = projects.flatMap(\.sessions).first(where: { $0.id == request.sessionID }) else { return }
            switch request.action {
            case .rename: startRenaming(session)
            case .togglePin: setPinned(session, !pinned.contains(session.id))
            case .toggleArchive: setArchived(session, !archived.contains(session.id))
            case .toggleUnread: toggleUnread(session)
            case .delete: deleting = session
            }
        }
        .onChange(of: navigator.request?.count) {
            guard let direction = navigator.request?.direction else { return }
            moveToProject(direction, proxy: proxy)
        }
        }
        .background(SidebarOutlineFinder(outline: outline))
        .focusedSceneValue(\.projectNavigator, navigator)
        .focusedSceneValue(\.sessionJumps, SessionJumps(sessions: !jumpsAllowed ? [] : Self.jumpTargets(
            shown: shownProjects, folded: collapsed, searching: ConversationSearch.isActive(query)
        ).compactMap { session in
            guard let project = shownProjects.first(where: { $0.sessions.contains { $0.id == session.id } }) else { return nil }
            return (session.title, { resume(project, session) })
        }))
        .toolbar(id: "conversations") {
            ToolbarItem(id: "newConversation") {
                Button("New Session", systemImage: "square.and.pencil", action: newConversation)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        // A sheet rather than an alert: an alert's text field didn't get
        // keyboard focus, which sat on Cancel.
        .sheet(item: $renaming) { session in
            RenameConversationSheet(title: session.title) { title in
                rename(session, title)
            }
        }
        .confirmationDialog(
            "Delete \u{201C}\(deleting?.title ?? "")\u{201D}?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let deleting { delete(deleting) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The session moves to the Trash, where you can get it back.")
        }
        .onAppear { highlighted = selectedID }
        // The open conversation changed elsewhere (a new one, another window).
        .onChange(of: selectedID) { highlighted = selectedID }
        .onChange(of: highlighted) { _, id in
            pendingOpen?.cancel()
            guard let id, id != selectedID else { return }
            if opensAfterPause() {
                pendingOpen = Task {
                    guard (try? await Task.sleep(for: SidebarLayout.keyboardOpenPause)) != nil else { return }
                    open(id)
                }
            } else {
                open(id)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search sessions")
        .searchFocused($searchFocused)
        .onChange(of: searchRequest) { searchFocused = true }
        .overlay {
            if projects.isEmpty {
                Text("No saved sessions yet.")
                    .foregroundStyle(Color(nsColor: Theme.quietLabel))
                    .padding()
            } else if ConversationSearch.isActive(query), shownProjects.isEmpty {
                EmptyState(ConversationSearch.noMatchesWording(query), systemImage: "magnifyingglass")
            }
        }
        .task(id: query) {
            // Restarts on every keystroke, so the count is spoken once
            // typing pauses, not once per letter.
            guard ConversationSearch.isActive(query) else { return }
            do {
                try await Task.sleep(for: ConversationSearch.announcementDelay)
            } catch {
                return
            }
            Announcer.announce(ConversationSearch.resultCountWording(shownCount))
        }
    }
}

extension SavedConversationList {
    /// Opens a Finder window with the project's folder selected. "This
    /// computer" has no folder, so it doesn't offer this.
    static func showInFinder(_ project: SessionHistory.ProjectSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([project.directory])
    }

    /// Opens the conversation with `id`, wherever it's listed.
    private func open(_ id: String) {
        guard let project = arranged.first(where: { $0.sessions.contains { $0.id == id } }),
              let session = project.sessions.first(where: { $0.id == id }) else { return }
        resume(project, session)
    }

    /// Where a conversation resumes: its own folder for a "This computer"
    /// one, otherwise its project's.
    static func folder(for session: SessionHistory.SessionSummary, in project: SessionHistory.ProjectSummary) -> URL {
        session.directory ?? project.directory
    }

    /// "Kitchen remodel, 2 hours ago, 3:14 PM", with "working" after the
    /// title while it is.
    /// What a row's dot says, most pressing first.
    enum RowStatus: String {
        case waiting = "needs your answer"
        case working
        case unread
        case archived
    }

    private func status(of session: SessionHistory.SessionSummary) -> RowStatus? {
        if waiting.contains(session.id) { return .waiting }
        if working.contains(session.id) { return .working }
        if unread.contains(session.id) { return .unread }
        if archived.contains(session.id) { return .archived }
        return nil
    }

    static func spokenRow(_ session: SessionHistory.SessionSummary, status: RowStatus? = nil) -> String {
        let when = session.lastModified.formatted(.relative(presentation: .named))
        let time = session.lastModified.formatted(.dateTime.hour().minute())
        // Grouped by date, the section doesn't say the project; the row does.
        let project = session.projectName.map { ["in \($0)"] } ?? []
        return ([session.title] + (status.map { [$0.rawValue] } ?? []) + [when, time] + project).joined(separator: ", ")
    }

    private func startRenaming(_ session: SessionHistory.SessionSummary) {
        renaming = session
    }
}

/// Asks for a conversation's new title, with the old one selected in the
/// field so typing replaces it.
struct RenameConversationSheet: View {
    let title: String
    let rename: (String) -> Void
    @State private var text = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Rename Session")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            TextField("Title", text: $text)
                // Without it VoiceOver read only the old title and "edit text".
                .accessibilityLabel("New title")
                .focused($fieldFocused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(minWidth: RenameLayout.minWidth)
        .onAppear {
            text = title
            fieldFocused = true
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        rename(trimmed)
        dismiss()
    }
}

enum RenameLayout {
    /// Room for a typical title without the sheet looking cramped.
    static let minWidth: CGFloat = 360
}

