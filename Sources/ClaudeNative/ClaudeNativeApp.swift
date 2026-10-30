import AppKit
import ClaudeNativeCore
import CodeHighlighting
import SwiftUI

/// Quitting mid-reply first interrupts the reply, as Stop does, so the
/// CLI saves what Claude wrote so far; each window's CLI is ended at once
/// after that, when the app terminates.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Off the main thread, before a code block needs them.
        Task.detached(priority: .utility) { CodeHighlighter.prepare() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Edits not yet saved first: quitting dropped them without a word.
        let unsaved = EditorDocument.unsaved
        if !unsaved.isEmpty {
            switch UnsavedChanges.ask(about: unsaved) {
            case .cancel:
                return .terminateCancel
            case .discard:
                break
            case .save:
                unsaved.forEach { $0.save() }
                // A save that stopped (changed on disk, say) has said why;
                // quitting now would lose those edits.
                guard EditorDocument.unsaved.isEmpty else { return .terminateCancel }
            }
        }
        guard AppModel.openModels.contains(where: \.isWorking) else { return .terminateNow }
        Task { @MainActor in
            await AppModel.interruptRepliesBeforeQuitting()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// CLIs a closed window let go of are still finishing an interrupt;
    /// ended here, as no window may be left to do it.
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.endExitingCLIsForQuit()
    }
}

@main
struct ClaudeNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Sign-in belongs to the CLI's account, so every window shares it.
    @State private var signIn = SignInModel()

    init() {
        // Run as a regular app even when launched as a bare SwiftPM binary.
        // It doesn't activate itself: launched in the background, it stays
        // there instead of taking focus from whatever the user is doing.
        NSApplication.shared.setActivationPolicy(.regular)
        // A write to a claude process that just exited must fail as an
        // error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup("Claude", id: NewWindowSession.windowID) {
            ContentView(signIn: signIn)
        }
        WindowGroup("Editor", for: URL.self) { $url in
            if let url {
                EditorWindow(url: url)
            }
        }
        .commands {
            WindowCommands()
            EditorCommands()
            ToolbarCommands()
            TextSizeCommands()
            SearchCommands()
            OpenFolderCommands()
            SoundCueCommands()
            MessageNavigationCommands()
            SessionCommands()
            PanelCommands()
            CommandGroup(after: .appSettings) {
                Button("Sign Out") { signIn.signOut() }
                    .disabled(!signIn.isSignedIn)
            }
        }
        Window("Keyboard Shortcuts", id: KeyboardShortcutsView.windowID) {
            KeyboardShortcutsView()
        }
        // Help > Keyboard Shortcuts opens it; the Window menu listed it a
        // second time.
        .commandsRemoved()
    }
}

struct ContentView: View {
    let signIn: SignInModel

    var body: some View {
        Group {
            if signIn.isSignedIn {
                // Sets its own minimum width, which grows with the side panel;
                // one here would override it.
                ChatView()
            } else {
                SignInView(model: signIn)
                    .frame(minWidth: ChatLayout.windowMinWidth)
            }
        }
        .frame(minHeight: 360)
        .task {
            if signIn.phase == .checking { await signIn.check() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await signIn.refresh() }
        }
    }
}

enum SidebarLayout {
    /// The dot beside a conversation that's working, about the Claude app's.
    static let workingDotDiameter: CGFloat = 7
    /// How long arrowing has to pause on a row before it opens.
    static let keyboardOpenPause: Duration = .milliseconds(500)
    /// The list starts a header's name 14.5 points in but ends the header
    /// 4.5 points short of the divider; this much more puts the plus
    /// button as far in from the right as the name is from the left.
    static let headerTrailingInset: CGFloat = 10
}

enum ChatLayout {
    /// Narrower than this, the message field and its buttons stop fitting.
    static let conversationMinWidth: CGFloat = 420
    /// The conversation list's ideal width: the Claude app's sidebar,
    /// measured at 288 points, so most titles fit on their one line.
    static let sidebarWidth: CGFloat = 288
    /// The conversation list's narrowest.
    static let sidebarMinWidth: CGFloat = 180
    /// Room for the list and the conversation side by side. Narrower, the
    /// window clipped both: the list on the left, Send on the right.
    static let windowMinWidth = sidebarMinWidth + conversationMinWidth
}

struct ChatView: View {
    /// One conversation per window.
    @State private var model = AppModel()
    @State private var draft = ""
    @State private var attachments: [ImageAttachment] = []
    /// Drafts of the conversations this window has left.
    @State private var drafts = Drafts()
    /// The diff for the permission request on screen, once built.
    @State private var permissionDiff: (requestID: String, diff: FileDiff?)?
    /// A finished tool row's changes, while their sheet is open.
    /// The editor and diff reader beside the conversation.
    @State private var sidePanel = SidePanel()
    @AppStorage("workingDirectory") private var storedDirectory = ""
    @AppStorage(TextScale.defaultsKey) private var textScale = TextScale.standard.factor
    @Environment(\.openWindow) private var openWindow
    @FocusState private var promptFocused: Bool
    /// Bumped by Command-F to put focus in the conversation search field.
    @State private var searchRequest = 0
    /// Whether /projects' list is showing.
    @State private var showingProjects = false
    /// Whether Command-K's palette is showing.
    @State private var showingPalette = false
    /// Whether this window is in front, for the sidebar's unread marks.
    @Environment(\.appearsActive) private var appearsActive
    @State private var modeMenu = MenuOpener()
    /// Pinned sessions, by id, one per line, as the sidebar keeps them.
    @AppStorage("pinnedConversations") private var pinnedStore = ""
    /// Archived sessions, read so the Session menu says Archive or Unarchive.
    @AppStorage(SessionArchive.defaultsKey) private var archivedStore = ""
    /// The open session, once it's saved and can be renamed or pinned.
    private var savedSessionID: String? {
        model.sessions.contains { $0.id == model.sessionID } ? model.sessionID : nil
    }
    @State private var modelMenu = MenuOpener()
    /// The toolbar title's menu, carried out by the sidebar.
    @State private var sessionActions = SessionActions()
    /// Command-B hides the sidebar, leaving the conversation.
    @State private var columns = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            ConversationList(model: model, open: open, newConversation: startNew, searchRequest: searchRequest, sessionActions: sessionActions)
                .navigationSplitViewColumnWidth(min: ChatLayout.sidebarMinWidth, ideal: ChatLayout.sidebarWidth)
        } detail: {
            conversation
                // Expanded, the panel covers the session rather than
                // replacing it: the session's view closing would end its
                // CLI. Hidden from VoiceOver underneath.
                .accessibilityHidden(sidePanel.isShown && sidePanel.isExpanded)
                .overlay {
                    if sidePanel.isShown && sidePanel.isExpanded {
                        SidePanelView(panel: sidePanel, base: model.workingDirectory)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .inspector(isPresented: Binding(
                    get: { sidePanel.isShown && !sidePanel.isExpanded },
                    // Expanding takes the inspector away; that isn't a close.
                    set: { shown in if !sidePanel.isExpanded { sidePanel.isShown = shown } }
                )) {
                    SidePanelView(panel: sidePanel, base: model.workingDirectory)
                        .inspectorColumnWidth(
                            min: SidePanelLayout.minWidth,
                            ideal: SidePanelLayout.idealWidth,
                            max: SidePanelLayout.maxWidth
                        )
                }
        }
        // With the side panel open the window needs its room too, or the
        // list and the panel's own buttons are clipped at the minimum.
        // With the side panel open the window needs its room too, or the
        // list and the panel's own buttons are clipped at the minimum.
        .frame(minWidth: ChatLayout.windowMinWidth + (sidePanel.isShown ? SidePanelLayout.minWidth : 0))
        .background {
            // F6 moves between the conversation and the editor, as in the
            // Claude desktop app's panes. Hidden: the menu bar has no slot
            // for it, and a hidden button still answers its shortcut.
            // Zero-size rather than .hidden(): SwiftUI drops the shortcuts of
            // hidden views. Each is unfocusable: with keyboard navigation on, Tab otherwise
            // stopped on every enabled one, silently, since VoiceOver can't
            // see them.
            Group {
                Button("Move Focus Between Session and Editor", action: switchFocus)
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(UInt16(NSF6FunctionKey)) ?? " ")), modifiers: [])
                    .focusable(false)
                // The menu shows Command-Plus, which needs Shift on most
                // keyboards; Command-Equals is the same key without it.
                Button("Bigger Text") { TextSizeCommands.change(&textScale, to: TextScale(textScale).bigger) }
                    .keyboardShortcut("=", modifiers: .command)
                    .focusable(false)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .focusedSceneValue(\.searchConversations, SearchConversationsAction(run: searchOrFind))
        .focusedSceneValue(\.focusMessageField, FocusMessageFieldAction { promptFocused = true })
        .focusedSceneValue(\.panelMenu, PanelMenuActions(panel: sidePanel, showChanges: showProjectChanges))
        .focusedSceneValue(\.sessionMenu, sessionMenuActions)
        .focusedSceneValue(\.windowMenu, WindowMenuActions(
            newSession: startNew,
            toggleSidebar: { columns = columns == .detailOnly ? .all : .detailOnly },
            isSidebarShown: columns != .detailOnly
        ))
        .sheet(isPresented: $showingPalette) {
            SessionPalette(projects: SideChats.hiding(model.projects, ids: SideChats.ids())) { project, session in
                open(SavedConversationList.folder(for: session, in: project), session)
            } start: { text in
                startNew()
                // In the field to send with Return: the new session's CLI
                // isn't ready to take it yet.
                draft = text
                Announcer.announceAfterFocusMove("New session. Return sends it.")
            }
        }
        .sheet(isPresented: $showingProjects) {
            ProjectsSheet(projects: ProjectsSheet.listed(model.projects)) { project in
                open(project.directory, nil)
            }
        }
        .background(WindowReader { model.window = $0 })
        .background(CloseGuard { sidePanel.unsavedDocuments })
        .focusedSceneValue(\.openFolder, OpenFolderAction(run: chooseFolder))
        .focusedSceneValue(\.sidePanel, sidePanel)
        // Looking at a conversation reads it.
        .onChange(of: appearsActive) { _, active in
            if active { WorkingConversations.shared.seen(model.sessionID) }
        }
        .onChange(of: model.sessionID) { _, id in
            if appearsActive { WorkingConversations.shared.seen(id) }
        }
        .onChange(of: sidePanel.isShown) { _, shown in
            if shown {
                makeRoomForSidePanel()
            } else {
                // Focus left on a control inside the closed panel strands
                // the keyboard and VoiceOver; bring it back to the message field.
                promptFocused = true
            }
        }
        .onChange(of: model.isWorking) { _, working in
            // A finished turn may have changed files open in the panel.
            if !working {
                sidePanel.checkDisk()
                sidePanel.refreshChanges()
                // Stop disappears when the turn ends; focus left on it would
                // fall to the toolbar, so bring it back to the message field.
                if Self.focusIsStranded { promptFocused = true }
            }
        }
    }

    /// Whether keyboard focus fell out of every control: the window
    /// itself, or nothing, is first responder.
    private static var focusIsStranded: Bool {
        guard let window = NSApp.keyWindow else { return false }
        return window.firstResponder == nil || window.firstResponder === window
    }

    /// Command-F: the editor's find bar while the editor has focus, as in
    /// any text editor; otherwise the conversation search field.
    private func searchOrFind() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, !editor.isFieldEditor, editor.usesFindBar {
            let show = NSMenuItem()
            show.tag = NSTextFinder.Action.showFindInterface.rawValue
            editor.performTextFinderAction(show)
            return
        }
        searchRequest += 1
    }

    /// What the Session menu can do in this window.
    private var sessionMenuActions: SessionMenuActions {
        let fork: (() -> Void)? = savedSessionID != nil && !model.isWorking ? { model.forkSession() } : nil
        let effort: (() -> Void)? = model.effortLevels.isEmpty ? nil : { modelMenu.open(heading: ModelMenu.effortHeading) }
        return SessionMenuActions(
            search: { showingPalette = true },
            chooseMode: modeMenu.open,
            chooseModel: modelMenu.open,
            chooseEffort: effort,
            rename: savedSessionID.map { id in { sessionActions.perform(.rename, on: id) } },
            togglePin: savedSessionID.map { id in { sessionActions.perform(.togglePin, on: id) } },
            toggleArchive: savedSessionID.map { id in { sessionActions.perform(.toggleArchive, on: id) } },
            toggleUnread: savedSessionID.map { id in { sessionActions.perform(.toggleUnread, on: id) } },
            isUnread: savedSessionID.map { WorkingConversations.shared.unread.contains($0) } ?? false,
            fork: fork,
            isArchived: savedSessionID.map { SessionArchive.ids(in: archivedStore).contains($0) } ?? false,
            isPinned: savedSessionID.map { id in pinnedStore.split(separator: "\n").contains { $0 == id } } ?? false
        )
    }

    private func showProjectChanges() {
        sidePanel.open(.projectChanges)
        sidePanel.refreshChanges()
    }

    /// Puts keyboard focus in the editor, or back in the message field when
    /// the editor already has it.
    private func switchFocus() {
        let responder = NSApp.keyWindow?.firstResponder as? NSTextView
        let editorHasFocus = responder.map { !$0.isFieldEditor } ?? false
        if sidePanel.isShown, case .file? = sidePanel.current, !editorHasFocus {
            sidePanel.focusEditor()
            Announcer.announce("Editor")
        } else if sidePanel.isShown, sidePanel.current != nil, promptFocused {
            // A diff or the changes list: VoiceOver lands on its summary
            // heading, which says where focus went.
            sidePanel.focusEditor()
        } else {
            promptFocused = true
            Announcer.announce("Message")
        }
    }

    private func startNew() {
        guard let directory = model.workingDirectory else { return chooseFolder() }
        switchDraft(to: nil)
        model.start(in: directory)
        promptFocused = true
    }

    /// The message field follows the conversation: the one being left
    /// keeps what's typed and attached, and the next gets its own back.
    private func switchDraft(to next: String?) {
        // Messages still queued are cleared by the switch: they're kept in
        // the draft, as typed, edit and all.
        let queued = model.queuedMessages.map { message in
            message.id == model.editingQueuedMessageID
                ? QueuedMessage(id: message.id, text: model.queuedEditingText ?? message.text, images: message.images)
                : message
        }
        if !queued.isEmpty {
            Announcer.announceAfterFocusMove(queued.count == 1
                ? "The queued message is kept in that session's message field."
                : "The \(queued.count) queued messages are kept in that session's message field.")
        }
        let leaving = Drafts.Draft(text: draft, attachments: attachments).keeping(queued: queued)
        let restored = drafts.switching(from: model.sessionID, keeping: leaving, to: next)
        draft = restored.text
        attachments = restored.attachments
    }

    /// From the sidebar: continues `session`, or starts a new conversation
    /// when it's nil, in `directory`, which becomes the window's folder.
    private func open(_ directory: URL, _ session: SessionHistory.SessionSummary?) {
        if let session, model.sessionIsOpenElsewhere(session.id) {
            // VoiceOver says the window it moves to.
            if AppModel.bringForward(session.id) { return }
            // After the palette or menu has closed: said at once, it was cut
            // off by VoiceOver following focus back to the message field.
            Announcer.announceAfterFocusMove("That session is already open in another window.")
            return
        }
        storedDirectory = directory.path
        switchDraft(to: session?.id)
        model.start(in: directory, resuming: session)
        if session == nil { promptFocused = true }
    }

    /// Widens the window when the side panel opens without room for both it
    /// and a readable conversation, as Xcode does for its inspector.
    private func makeRoomForSidePanel() {
        guard let window = NSApp.keyWindow, let screen = window.screen else { return }
        let needed = ChatLayout.sidebarWidth + ChatLayout.conversationMinWidth + SidePanelLayout.idealWidth
        guard window.frame.width < needed else { return }
        var frame = window.frame
        frame.size.width = min(needed, screen.visibleFrame.width)
        frame.origin.x = max(screen.visibleFrame.minX, min(frame.origin.x, screen.visibleFrame.maxX - frame.width))
        window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if let error = model.launchError, !model.canRetrySessionLoad {
                Text(error)
                    .foregroundStyle(Color(nsColor: Theme.errorText))
                    .padding()
            }
            ConversationContent(
                model: model,
                textScale: textScale,
                sendSuggestion: { prompt in
                    model.send(prompt)
                    // The suggestion removes itself with the empty
                    // state; without this, focus lands on the toolbar.
                    promptFocused = true
                },
                retrySessionLoad: {
                    model.retrySessionLoad()
                    promptFocused = true
                },
                resumeSession: { session in
                    guard let directory = model.workingDirectory else { return }
                    open(session.directory ?? directory, session)
                },
                openFile: { sidePanel.open(.file($0)) },
                openInNewWindow: { openWindow(value: $0) },
                showChanges: { entry in
                    Task {
                        if let diff = await DiffLoader.load(entry: entry) {
                            sidePanel.open(.changes(diff))
                        } else {
                            Announcer.announce("Couldn't show the changes for this step.", urgency: .urgent)
                        }
                    }
                }
            )
            if !model.queuedMessages.isEmpty {
                QueuedMessagesView(model: model, interactionEnded: { promptFocused = true })
            }
            Composer(
                draft: $draft,
                attachments: $attachments,
                focus: $promptFocused,
                isReady: model.canSend,
                isWorking: model.isWorking,
                usageLimits: model.usageLimits,
                contextUsage: model.contextUsage,
                send: send,
                stop: {
                    model.interrupt()
                    // The Stop button goes away with the turn; keep focus
                    // in the field rather than letting it fall to the toolbar.
                    promptFocused = true
                },
                attachImages: attachImages,
                commands: SlashCommand.withLocal(model.commands),
                mentionRoot: model.workingDirectory,
                modeMenu: ModeMenu(selection: $model.permissionModeChoice, opener: modeMenu),
                folderMenu: FolderMenu(
                    current: model.workingDirectory,
                    recent: ProjectsSheet.listed(model.projects),
                    choose: { open($0, nil) },
                    openFolder: chooseFolder
                ),
                modelMenu: ModelMenu(
                    model: $model.selectedModel, effort: $model.effortChoice,
                    models: model.models, effortLevels: model.effortLevels,
                    opener: modelMenu
                ),
                placeholder: model.transcript.entries.isEmpty ? ComposerPlaceholder.newConversation : ComposerPlaceholder.inConversation
            )
        }
        .frame(minWidth: ChatLayout.conversationMinWidth)
        .dropDestination(for: URL.self) { urls, _ in add(urls) }
        .modifier(PastesImages(isFocused: $promptFocused, attach: { attachments += $0 }, addFiles: { _ = add($0) }))
        .onDisappear {
            // Kept for Reopen Closed Session.
            if let directory = model.workingDirectory, let session = model.sessions.first(where: { $0.id == model.sessionID }) {
                ClosedSessions.shared.remember(directory, session)
            }
            model.close()
            sidePanel.terminal.stop()
            sidePanel.sideChat.close()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.close(appIsQuitting: true)
            sidePanel.terminal.stop()
            sidePanel.sideChat.close(appIsQuitting: true)
        }
        .navigationTitle(WindowTitle.forConversation(model.sessionTitle))
        .navigationSubtitle(model.workingDirectory?.lastPathComponent ?? "No folder")
        // The window keeps its title and subtitle (VoiceOver and the Window
        // menu name it by them), but the toolbar shows WindowHeading
        // instead: macOS draws the subtitle at 3.32:1 in light.
        .toolbar(removing: .title)
        // A customizable toolbar, so Control-click > Icon and Text can put a
        // word under every button; at low vision a bare symbol is a guess.
        .toolbar(id: "conversation") {
            ToolbarItem(id: "title", placement: .navigation) {
                WindowHeading(
                    title: WindowTitle.forConversation(model.sessionTitle),
                    folder: FolderLine.shown(folder: model.workingDirectory?.lastPathComponent ?? "No folder", branch: model.branch),
                    spokenFolder: FolderLine.spoken(folder: model.workingDirectory?.lastPathComponent ?? "No folder", branch: model.branch),
                    sessionID: savedSessionID,
                    actions: sessionActions
                )
            }
            ToolbarItem(id: "chooseFolder") {
                // The same words as File > Open Folder… and the Claude app.
                Button("Open Folder", systemImage: "folder", action: chooseFolder)
            }
            ToolbarItem(id: "openFile") {
                Button("Open File", systemImage: "doc.text", action: openFileInEditor)
                    .keyboardShortcut("o", modifiers: .command)
            }
            ToolbarItem(id: "changes") {
                // Toolbar buttons are named by their title; a separate
                // accessibility label is ignored there.
                // With changes, the lines they add and remove, as the
                // Claude app's changes pill shows them ("+12 −3").
                if let counts = model.changeCounts, !counts.isEmpty {
                    Button(action: showProjectChanges) {
                        Text(counts.title)
                            .monospacedDigit()
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .accessibilityLabel(counts.spoken)
                    }
                    .help("\(counts.spoken) (Command-Shift-D)")
                } else {
                    Button("Uncommitted Changes", systemImage: "arrow.triangle.branch", action: showProjectChanges)
                        .help("Uncommitted Changes (Command-Shift-D)")
                }
            }
            ToolbarItem(id: "files") {
                Button("Files", systemImage: "list.bullet.indent") { sidePanel.open(.files) }
                    .help("Files (Shift-Command-F)")
            }
            ToolbarItem(id: "terminal") {
                Button("Terminal", systemImage: "terminal") { sidePanel.open(.terminal) }
                    .help("Terminal (Command-J)")
            }
            ToolbarItem(id: "sideChat") {
                Button("Side Chat", systemImage: "bubble.left.and.bubble.right") { sidePanel.open(.sideChat) }
                    .help("Side Chat (Command-Semicolon)")
            }
            ToolbarItem(id: "editor") {
                Button("Editor", systemImage: "sidebar.trailing") { sidePanel.isShown.toggle() }
                    .help(sidePanel.isShown ? "Hide Editor" : "Show Editor")
                    .accessibilityLabel(sidePanel.isShown ? "Hide Editor" : "Show Editor")
            }
        }
        .sheet(isPresented: Binding(
            get: { model.pendingQuestions != nil },
            // The sheet's own buttons answer; dismissal must not.
            set: { _ in }
        )) {
            if let questions = model.pendingQuestions, let id = model.pendingPermission?.requestID {
                // Each request answered as itself, on a sheet of its own.
                QuestionsSheet(
                    questions: questions,
                    onAnswer: { answers in model.answerQuestions(answers, for: id) },
                    onSkip: { model.answerPermission(allow: false, for: id) }
                )
                .id(id)
            }
        }
        .task(id: model.pendingPermission?.requestID) {
            guard let request = model.pendingPermission, model.pendingQuestions == nil else { return }
            permissionDiff = (request.requestID, await DiffLoader.load(request: request))
        }
        .sheet(isPresented: Binding(
            get: { model.pendingPermission != nil && model.pendingQuestions == nil && diffIsSettled },
            // Only the sheet's buttons answer; dismissal must not, and
            // SwiftUI may reset this before running Allow's action.
            set: { _ in }
        )) {
            if let request = model.pendingPermission {
                // Answers carry the request they were given for, and each
                // request gets a sheet of its own: Revise's state carried
                // over to the next request on the same sheet.
                let id = request.requestID
                PermissionSheet(request: request, diff: currentPermissionDiff, base: model.workingDirectory, revise: { note in
                    model.answerPermission(allow: false, denialMessage: PermissionWording.revisionMessage(note), for: id)
                }) { allow, remember in
                    model.answerPermission(allow: allow, remember: remember, for: id)
                }
                .id(id)
            }
        }
        .task {
            if let (directory, session) = NewWindowSession.take() {
                // Opened by a row's Open in New Window.
                open(directory, session)
            } else if !storedDirectory.isEmpty {
                model.start(in: URL(fileURLWithPath: storedDirectory))
            } else {
                // The sidebar lists every project to pick from meanwhile.
                model.refreshSessions()
                chooseFolder()
            }
            promptFocused = true
        }
    }

    /// The pending request's diff, when it's a file change that could be diffed.
    private var currentPermissionDiff: FileDiff? {
        guard let request = model.pendingPermission, permissionDiff?.requestID == request.requestID else { return nil }
        return permissionDiff?.diff
    }

    /// The plain prompt waits while a file change's diff is being built, so
    /// the alert doesn't flash before the diff sheet replaces it.
    private var diffIsSettled: Bool {
        guard let request = model.pendingPermission else { return true }
        let isFileTool = ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(request.toolName)
        return !isFileTool || permissionDiff?.requestID == request.requestID
    }

    private func send() {
        // The app's own commands are answered here, not sent. Images stay
        // attached: with any, "/projects" went to the CLI as text.
        if SlashCommand.localCommand(in: draft) == .projects {
            draft = ""
            showingProjects = true
            return
        }
        // Return in the field bypasses the disabled Send button.
        guard model.canSend else { return }
        model.send(draft, images: attachments)
        draft = ""
        attachments = []
    }

    private func attachImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.message = "Choose images to send with your message."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// Images go with the message; any other file dropped is mentioned in
    /// it, as the Claude app does, so Claude reads it.
    @discardableResult
    private func add(_ urls: [URL]) -> Bool {
        var images: [ImageAttachment] = []
        var others: [URL] = []
        for url in urls {
            if let image = ImageAttachment(fileURL: url) { images.append(image) } else if url.isFileURL { others.append(url) }
        }
        attachments += images
        draft = FileMentionSearch.mentioning(others, under: model.workingDirectory, in: draft)
        var said: [String] = []
        if !images.isEmpty { said.append(images.count == 1 ? "Attached \(images[0].name)." : "Attached \(images.count) images.") }
        if !others.isEmpty { said.append(others.count == 1 ? "Mentioned \(others[0].lastPathComponent)." : "Mentioned \(others.count) files.") }
        // After VoiceOver follows the drop back to the window; said at once,
        // it went unheard behind that (measured with a drag under VoiceOver).
        if !said.isEmpty { Announcer.announceAfterFocusMove(said.joined(separator: " "), urgency: .urgent) }
        return !images.isEmpty || !others.isEmpty
    }

    private func openFileInEditor() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = model.workingDirectory
        panel.message = "Choose files to open in the editor."
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { sidePanel.open(.file($0)) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.message = "Choose the folder Claude works in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        storedDirectory = url.path
        switchDraft(to: nil)
        model.start(in: url)
    }
}

/// The conversation, or the suggestions shown before it starts. This is the
/// only view that reads the transcript: SwiftUI re-runs the body of every
/// view that read a changed property, so while a reply streams, each update
/// re-runs this body alone instead of the window's toolbar, sidebar and
/// composer as well.
struct ConversationContent: View {
    /// View > Show Tool Output (Control-O), for every window.
    @AppStorage(ToolOutputSetting.defaultsKey) private var showsToolOutput = false
    let model: AppModel
    /// Where the Go menu's message moves reach this window's conversation.
    @State private var navigator = MessageNavigator()
    let textScale: Double
    let sendSuggestion: (String) -> Void
    let retrySessionLoad: () -> Void
    /// Opens one of the folder's sessions, from a Resume step.
    var resumeSession: (SessionHistory.SessionSummary) -> Void = { _ in }
    let openFile: (URL) -> Void
    let openInNewWindow: (URL) -> Void
    let showChanges: (TranscriptEntry) -> Void

    var body: some View {
        if model.canRetrySessionLoad {
            SessionRecoveryView(message: model.launchError ?? "Retry loading this session.", retry: retrySessionLoad)
        } else if model.transcript.entries.isEmpty {
            EmptyConversation(
                isReady: model.canSend,
                steps: EmptyConversation.steps(
                    latest: model.sessions.first,
                    hasChanges: model.changeCounts.map { $0.added + $0.removed > 0 } ?? false
                ),
                send: sendSuggestion,
                resume: resumeSession
            )
        } else {
            TranscriptView(
                transcript: model.transcript,
                revision: model.transcriptRevision,
                workingDirectory: model.workingDirectory,
                isWorking: model.isWorking,
                openFile: openFile,
                sessionID: model.sessionID,
                openInNewWindow: openInNewWindow,
                showChanges: showChanges,
                textScale: textScale,
                navigator: navigator,
                showsToolOutput: showsToolOutput
            )
            .focusedSceneValue(\.messageNavigator, navigator)
        }
    }
}

/// What File > Open Folder… does in the focused window.
struct OpenFolderAction {
    let run: () -> Void
}

extension FocusedValues {
    @Entry var openFolder: OpenFolderAction?
}

/// File > Open Folder…, Command-Shift-O, as in the Claude app: starts a
/// conversation in a folder, which becomes a project in the sidebar. Only
/// the toolbar had it, with no shortcut.
struct OpenFolderCommands: Commands {
    @FocusedValue(\.openFolder) private var openFolder

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") { openFolder?.run() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(openFolder == nil)
        }
    }
}

/// What Command-F does in the focused window.
struct SearchConversationsAction {
    let run: () -> Void
}

extension FocusedValues {
    @Entry var searchConversations: SearchConversationsAction?
    @Entry var sidePanel: SidePanel?
}

/// View > Show Editor and Hide Editor, Control-Command-I: the side panel by
/// the name its toolbar button and Close Editor use. SwiftUI's own
/// InspectorCommands called it "Show Inspector".
struct EditorCommands: Commands {
    @FocusedValue(\.sidePanel) private var panel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(panel?.isShown == true ? "Hide Editor" : "Show Editor") { panel?.isShown.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(panel == nil)
        }
    }
}

/// Edit > Search Conversations, Command-F. A menu item rather than a
/// hidden button: measured, a hidden Command-F button fired with the list
/// focused but not with the message field focused. The menu bar gets key
/// equivalents before any view does.
struct SearchCommands: Commands {
    @FocusedValue(\.searchConversations) private var search

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search Sessions") { search?.run() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(search == nil)
        }
    }
}

/// Command-Plus, Command-Minus and Command-0 size the conversation's text,
/// as in Messages and Safari, on top of the system's text size.
struct TextSizeCommands: Commands {
    @AppStorage(TextScale.defaultsKey) private var factor = TextScale.standard.factor

    private var scale: TextScale { TextScale(factor) }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { Self.change(&factor, to: scale.bigger) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(scale.bigger == nil)
            Button("Smaller Text") { Self.change(&factor, to: scale.smaller) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(scale.smaller == nil)
            Button("Actual Size") { Self.change(&factor, to: .standard) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(scale == .standard)
        }
    }

    static func change(_ factor: inout Double, to new: TextScale?) {
        guard let new else { return }
        factor = new.factor
        Announcer.announce(new.spoken)
    }
}
