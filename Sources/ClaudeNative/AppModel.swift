import AppKit
import ClaudeNativeCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    /// The conversation as the view shows it. While Claude's text streams
    /// this is replaced at most once per `UpdatePacing.interval`; anything
    /// else shows at once (see `publishTranscript()`).
    private(set) var transcript = Transcript()
    /// Bumped each time `transcript` is replaced; the transcript view syncs on it.
    private(set) var transcriptRevision = 0
    /// The conversation as of the latest event, ahead of `transcript` by at
    /// most one pacing interval of streamed text.
    @ObservationIgnored private var liveTranscript = Transcript()
    @ObservationIgnored private var pacing = UpdatePacing()
    /// The trailing update for text still waiting to be shown.
    @ObservationIgnored private var pendingPublish: Task<Void, Never>?
    /// Times the update after a publish, until the main run loop next waits.
    @ObservationIgnored private var costObserver: CFRunLoopObserver?
    /// Which events earn a sound cue. It follows the conversation even with
    /// cues off, so turning them on mid-turn stays correct.
    @ObservationIgnored private var soundCues = SoundCuePolicy()
    private(set) var permissions = PermissionQueue() {
        didSet {
            reportWorking()
            // Answered, withdrawn or dropped: its notification no longer
            // applies.
            let gone = oldValue.waiting.map(\.requestID).filter { id in
                !permissions.waiting.contains { $0.requestID == id }
            }
            if !gone.isEmpty { withdrawNotifications(gone.map(permissionNotificationID)) }
        }
    }
    /// The permission request on screen; later ones wait their turn.
    var pendingPermission: PermissionRequest? { permissions.current }
    /// Only dispatched messages count as working; pending messages stay
    /// local until the current turn finishes.
    private var outstandingTurns = 0 {
        didSet { isWorking = outstandingTurns > 0 }
    }
    private(set) var isWorking = false {
        didSet { reportWorking() }
    }
    /// Messages sent while Claude works, held here until its turn ends.
    /// They belong to this window's conversation and go with it.
    private(set) var queuedMessages: [QueuedMessage] = []
    private(set) var queueIsPaused = false
    private(set) var editingQueuedMessageID: UUID?
    private(set) var queuedEditingText: String?
    @ObservationIgnored private let cliExecutable: URL?
    private(set) var workingDirectory: URL?
    /// Shown above the conversation, and spoken when it appears so a
    /// VoiceOver user hears a failed send or load.
    private(set) var launchError: String? {
        didSet {
            if let launchError, launchError != oldValue { Announcer.announce(launchError, urgency: .urgent) }
        }
    }
    /// The account's usage limits, from the latest rate-limit line.
    private(set) var usageLimits: UsageLimits?
    /// How full the context window was after the last turn.
    private(set) var contextUsage: ContextUsage?
    /// What the CLI said it offers, once it has answered `initialize`.
    private(set) var models: [ModelOption] = []
    /// The slash commands this CLI accepts, for the message field's picker.
    private(set) var commands: [SlashCommand] = []
    var selectedModel = "default" {
        didSet { if selectedModel != oldValue { control { try await $0.setModel(self.selectedModel) } } }
    }
    /// The mode the live conversation is in. A permission answer such as
    /// "Allow Edits for This Conversation" changes it for this conversation
    /// only.
    var permissionMode = "default" {
        didSet {
            guard permissionMode != oldValue, !takingModeFromCLI else { return }
            control { try await $0.setPermissionMode(self.permissionMode) }
        }
    }
    /// Set while the mode is taken from what the CLI reports, which needs
    /// no request back.
    @ObservationIgnored private var takingModeFromCLI = false

    private func takeModeFromCLI(_ mode: String) {
        takingModeFromCLI = true
        permissionMode = mode
        takingModeFromCLI = false
    }
    /// How hard the model works: "auto" leaves it to the CLI, otherwise one of
    /// the model's supportedEffortLevels. There is no control request for
    /// it, so a change restarts the conversation's process with --resume.
    private(set) var effort = "auto"

    var effortChoice: String {
        get { effort }
        set {
            guard newValue != effort else { return }
            effort = newValue
            applyEffort()
        }
    }

    /// Effort levels the selected model accepts.
    var effortLevels: [String] {
        models.first { $0.value == selectedModel }?.supportedEffortLevels ?? []
    }

    private func applyEffort() {
        guard let directory = workingDirectory else { return }
        if canRetrySessionLoad {
            retrySessionLoad()
            return
        }
        guard !isWorking else {
            launchError = "Effort changes once Claude finishes this reply."
            pendingEffortRestart = true
            return
        }
        let spoken = "Effort set to \(EffortWording.title(effort).lowercased())."
        // The list refreshes after each turn, so a conversation's first
        // reply may not be in it yet; read the folder again before giving up.
        let saved = sessionID.flatMap { id in
            sessions.first { $0.id == id }
                ?? SessionHistory.listSessions(cwd: directory).first { $0.id == id }
        }
        // A new conversation with nothing sent: a fresh process with the new
        // effort is the same conversation. Returning here instead left the
        // picker showing an effort the CLI never got. A saved conversation
        // whose history is still loading (or failed to load) also has an
        // empty transcript, so this keys on there being no saved session;
        // keying on the transcript alone dropped it for a new conversation.
        if saved == nil, liveTranscript.entries.isEmpty {
            pendingEffortRestart = false
            start(in: directory, preservingQueue: true)
            Announcer.announce(spoken)
            return
        }
        if saved == nil, let source = forkedFrom {
            pendingEffortRestart = false
            start(in: directory, resuming: source, fork: true, preservingQueue: true)
            Announcer.announce(spoken)
            return
        }
        guard let saved else {
            pendingEffortRestart = true
            queueIsPaused = !queuedMessages.isEmpty
            launchError = "Couldn't apply the new effort: this session isn't saved yet."
            return
        }
        pendingEffortRestart = false
        start(in: directory, resuming: saved, preservingQueue: true)
        Announcer.announce(spoken)
    }

    private var pendingEffortRestart = false
    /// The session a fork was made from, until the fork has an id of its
    /// own (the CLI gives it one with the first message). Starting the
    /// CLI again before then, for effort or a reconnect, forks it again:
    /// it said "this session isn't saved yet", or reconnected to a new
    /// empty conversation and lost the fork.
    private var forkedFrom: SessionHistory.SessionSummary?

    private struct FailedSessionLoad {
        let session: SessionHistory.SessionSummary
        let fork: Bool
    }
    /// Keep the source even when it has disappeared from the refreshed
    /// sidebar. Retry must not turn a failed resume into a new session.
    private var failedSessionLoad: FailedSessionLoad?
    var canRetrySessionLoad: Bool { failedSessionLoad != nil }
    var sessionTitle: String? {
        sessions.first { $0.id == sessionID }?.title ?? failedSessionLoad?.session.title
    }

    func retrySessionLoad() {
        guard let failedSessionLoad, let workingDirectory else { return }
        start(in: workingDirectory, resuming: failedSessionLoad.session, fork: failedSessionLoad.fork, preservingQueue: true)
    }

    /// The mode chosen in the toolbar; every new conversation starts in it.
    private var chosenPermissionMode = "default"

    /// The composer's Mode menu: a choice there applies now and to
    /// later conversations.
    var permissionModeChoice: String {
        get { permissionMode }
        set {
            chosenPermissionMode = newValue
            permissionMode = newValue
        }
    }
    private var cli: ClaudeCLI?
    /// The CLI has started and can take messages.
    private(set) var isReady = false
    /// The CLI ended on its own between turns. A message sent now starts it
    /// again, resuming this conversation, and then goes out.
    private(set) var cliEnded = false
    /// Whether the message field can send: Claude is ready, or ended and
    /// will be started again for the message.
    var canSend: Bool { isReady || cliEnded }
    /// Saved conversations for the working folder, newest first.
    private(set) var sessions: [SessionHistory.SessionSummary] = [] {
        didSet { mergeProjects() }
    }
    /// Every project with saved conversations, for the sidebar, with this
    /// window's folder always among them.
    private(set) var projects: [SessionHistory.ProjectSummary] = []
    /// Projects as last read from disk, before this window's folder is
    /// merged in.
    private var listedProjects: [SessionHistory.ProjectSummary] = []
    /// The conversation this window is in, once the CLI has named it.
    private(set) var sessionID: String? {
        didSet { reportWorking() }
    }

    /// Every open window's model, so deleting a conversation can stop each
    /// window showing it. Weak, and a window leaves it on close().
    @ObservationIgnored private static let registry = NSHashTable<AppModel>.weakObjects()

    /// `cliExecutable` stands in for the located claude command in tests.
    init(cliExecutable: URL? = nil) {
        self.cliExecutable = cliExecutable
        Self.registry.add(self)
    }

    static var openModels: [AppModel] { registry.allObjects }

    /// The running CLI's process, for tests.
    func cliProcessIdentifier() async -> Int32? { await cli?.processIdentifier }

    static func models(showing sessionID: String) -> [AppModel] {
        openModels.filter { $0.sessionID == sessionID }
    }

    /// The window showing this model, set by the window once it's in one.
    @ObservationIgnored weak var window: NSWindow?

    /// Whether the user can see this conversation: its window is the main
    /// one in the active app, as SwiftUI's appearsActive has it.
    var isSeen: Bool { NSApp?.isActive == true && window?.isMainWindow == true }

    /// Brings forward the window already showing `sessionID`, as choosing
    /// it would have opened it: a refusal alone left the user to find that
    /// window, and its unread mark stayed. False if no window has it.
    static func bringForward(_ sessionID: String) -> Bool {
        guard let window = models(showing: sessionID).first?.window else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    static func isBeingDeleted(_ sessionID: String) -> Bool { deleting.contains(sessionID) }

    /// Whether another window shows `sessionID`. Opening it here too would
    /// have two CLIs writing one file; the sidebar, Command-K and
    /// Command-1 to 9 opened it anyway (Open in New Window refused).
    func sessionIsOpenElsewhere(_ sessionID: String) -> Bool {
        Self.models(showing: sessionID).contains { $0 !== self }
    }

    /// Conversations being deleted. A second Delete of one does nothing
    /// rather than skipping the wait for its CLI.
    private static var deleting = Set<String>()
    /// CLIs let go of when their window moved on or closed, by the
    /// conversation they had, until they've exited.
    private static var exiting: [String: [UUID: Task<Void, Never>]] = [:]

    private static func trackExiting(_ cli: ClaudeCLI, for sessionID: String?) {
        let token = UUID()
        exitingCLIs[token] = cli
        let stopping = Task {
            await cli.stopAndWait()
            exitingCLIs[token] = nil
        }
        guard let sessionID else { return }
        exiting[sessionID, default: [:]][token] = stopping
        Task {
            await stopping.value
            exiting[sessionID]?[token] = nil
            if exiting[sessionID]?.isEmpty == true { exiting[sessionID] = nil }
        }
    }

    /// Returns once every CLI let go of `sessionID` has exited, including
    /// one let go of while this waits (another window leaving it), as
    /// release(_:from:startNewHere:) does.
    private static func waitForExiting(_ sessionID: String) async {
        var waited = Set<UUID>()
        while let (token, stopping) = exiting[sessionID]?.first(where: { !waited.contains($0.key) }) {
            waited.insert(token)
            await stopping.value
        }
    }

    /// CLIs a window let go of that are still interrupting or exiting.
    private static var exitingCLIs: [UUID: ClaudeCLI] = [:]

    /// Ends every CLI still exiting, at once: the app is quitting and can't
    /// wait out an interrupt's grace, and one left would outlive it.
    static func endExitingCLIsForQuit() {
        for cli in exitingCLIs.values { cli.terminateNow() }
    }

    /// Lets go of a conversation before its file is deleted. Waits for every
    /// CLI that has it, in open windows and ones still exiting, and moves
    /// each window still showing it to a new conversation (`startNewHere`
    /// for `window`). Each window is checked again after its wait: one that
    /// moved to another conversation or closed meanwhile is left alone.
    /// Returns false if the conversation is already being deleted; call
    /// finishedDeleting(_:) after a true.
    static func release(_ sessionID: String, from window: AppModel, startNewHere: () -> Void) async -> Bool {
        guard deleting.insert(sessionID).inserted else { return false }
        // Until nothing holds it: a window leaving the conversation while
        // this waits adds an exiting CLI, so each pass looks again.
        var waited = Set<UUID>()
        // A window with no folder can't be moved on; it's stopped once.
        var stopped = Set<ObjectIdentifier>()
        while true {
            if let (token, stopping) = exiting[sessionID]?.first(where: { !waited.contains($0.key) }) {
                waited.insert(token)
                await stopping.value
                continue
            }
            guard let showing = models(showing: sessionID).first(where: { !stopped.contains(ObjectIdentifier($0)) }) else { break }
            await showing.stopAndWait()
            // It may have moved on or closed while this waited; if so its new
            // conversation is left alone (and the CLI it left is in `exiting`).
            guard openModels.contains(where: { $0 === showing }), showing.sessionID == sessionID else { continue }
            stopped.insert(ObjectIdentifier(showing))
            if showing === window {
                startNewHere()
            } else if let folder = showing.workingDirectory {
                showing.start(in: folder)
            }
        }
        return true
    }

    static func finishedDeleting(_ sessionID: String) {
        deleting.remove(sessionID)
    }

    /// Session > Fork Session, as the Claude app forks: carries on from a
    /// copy of this session, so the original stays as it was.
    /// The title a fork takes once its file is saved: the CLI copies the
    /// original's, so the sidebar listed two rows with the same name.
    @ObservationIgnored private var pendingForkTitle: String?

    func forkSession() {
        guard let directory = workingDirectory, !isWorking,
              let session = sessions.first(where: { $0.id == sessionID }) else { return }
        start(in: directory, resuming: session, fork: true)
        pendingForkTitle = SessionHistory.forkTitle(session.title)
        Announcer.announce("Forked. New messages go to a copy; the original session stays as it was.")
    }

    /// Starts a new conversation in `directory`, or continues `resuming`;
    /// `fork` continues from a copy, leaving `resuming` as it was.
    func start(in directory: URL, resuming: SessionHistory.SessionSummary? = nil, fork: Bool = false, preservingQueue: Bool = false) {
        // A conversation on its way to the Trash isn't reopened.
        if let resuming, Self.deleting.contains(resuming.id) {
            Announcer.announce("That session is being deleted.")
            return
        }
        let isLoadRetry = failedSessionLoad != nil && failedSessionLoad?.session.id == resuming?.id
        failedSessionLoad = nil
        // Another conversation doesn't inherit what was queued for this one.
        if !preservingQueue {
            queuedMessages = []
            editingQueuedMessageID = nil
            queuedEditingText = nil
            queueIsPaused = false
            pendingEffortRestart = false
        }
        // The new CLI lists its own commands once it's ready.
        commands = []
        if let previous = cli {
            // Kept until it has exited, so deleting the conversation it had
            // waits for it.
            Self.trackExiting(previous, for: sessionID)
        }
        cli = nil
        isReady = false
        cliEnded = false
        let movedFolder = workingDirectory.map(SessionHistory.canonicalPath) != SessionHistory.canonicalPath(directory)
        workingDirectory = directory
        if movedFolder {
            // Until the refresh below lands, the new folder shows what the
            // project list already knows of it, not the old folder's list.
            let key = SessionHistory.canonicalPath(directory)
            sessions = listedProjects.first { SessionHistory.canonicalPath($0.directory) == key }?.sessions ?? []
        }
        // A fork's id comes from the CLI once it starts.
        sessionID = fork ? nil : resuming?.id
        forkedFrom = fork ? resuming : (preservingQueue ? forkedFrom : nil)
        // Only the fork this start makes is retitled.
        pendingForkTitle = nil
        // A mode granted for one conversation ends with it; starting its
        // CLI again (an effort change, a reconnect, both preserving the
        // queue) keeps it, or Claude asked for permission again.
        if !preservingQueue { permissionMode = chosenPermissionMode }
        contextUsage = nil
        outstandingTurns = 0
        permissions.clear()
        liveTranscript = Transcript()
        soundCues = SoundCuePolicy()
        publishTranscript()
        guard let executable = cliExecutable ?? CLILocator.locate() else {
            launchError = "Couldn't find the claude command. Set \(CLILocator.environmentOverride) to its path."
            queueIsPaused = !queuedMessages.isEmpty
            return
        }
        // A new process starts with the window's current choices, so the
        // pickers keep telling the truth after switching conversations.
        let cli = ClaudeCLI(
            executable: executable,
            workingDirectory: directory,
            model: selectedModel == "default" ? nil : selectedModel,
            permissionMode: permissionMode,
            effort: effort == "auto" ? nil : effort
        )
        self.cli = cli
        launchError = nil
        Task { [self] in
            if let resuming {
                // A CLI just let go of this conversation may still be saving
                // an interrupted reply; read the file once it's done.
                await Self.waitForExiting(resuming.id)
                guard self.cli === cli else { return }
                let fileURL = resuming.fileURL
                do {
                    let saved = try await Task.detached { try SessionHistory.loadSession(fileURL: fileURL) }.value
                    guard self.cli === cli else { return }
                    // A previously listed prompt proves this session had
                    // content. A truncated or wholly unreadable replacement
                    // must not resume as a new, empty conversation.
                    guard !saved.entries.isEmpty || (resuming.firstPrompt.isEmpty && saved.diagnostics.isEmpty) else {
                        throw SessionHistory.HistoryError.unreadable(path: fileURL.path)
                    }
                    liveTranscript = Transcript(restoring: saved.entries)
                    soundCues = SoundCuePolicy(restoring: saved.entries)
                    publishTranscript()
                } catch {
                    guard self.cli === cli else { return }
                    self.cli = nil
                    failedSessionLoad = FailedSessionLoad(session: resuming, fork: fork)
                    queueIsPaused = !queuedMessages.isEmpty
                    launchError = "The saved conversation couldn't be read. Retry loading it or choose another session."
                    return
                }
            }
            guard self.cli === cli else { return }
            do {
                try await cli.start(resumeSessionID: resuming?.id, fork: fork)
                guard self.cli === cli else { return }
                isReady = true
                if isLoadRetry {
                    Task { [weak self] in
                        guard (try? await Task.sleep(for: Announcer.afterFocusMoveDelay)) != nil,
                              self?.cli === cli, self?.isReady == true else { return }
                        Announcer.announce("Session loaded.")
                    }
                }
                dispatchNextQueuedMessage()
            } catch {
                guard self.cli === cli else { return }
                launchError = error.localizedDescription
                queueIsPaused = !queuedMessages.isEmpty
                return
            }
            for await event in cli.events {
                // A replaced process may still be draining; its events
                // belong to the conversation that was left.
                guard self.cli === cli else { break }
                handle(event)
            }
            if self.cli === cli {
                isReady = false
                cliEnded = true
                outstandingTurns = 0
                queueIsPaused = !queuedMessages.isEmpty
                permissions.clear()
                // Otherwise the field went quiet: Send disabled, Return doing
                // nothing, and nothing said.
                // Setting it announces it.
                launchError = queuedMessages.isEmpty
                    ? "Claude stopped running. Your next message starts it again."
                    : "Claude stopped running. Reconnect sends the queued messages."
            }
        }
        refreshSessions()
    }

    /// The start of Claude's latest reply, for a notification.
    private var lastReplyPreview: String {
        let text = liveTranscript.entries.last { $0.kind == .assistant }?.text ?? ""
        return String(text.prefix(140))
    }

    /// Ends this window's claude process, as the window closes or the app
    /// quits. A process left running would carry on with its turn,
    /// including edits it was allowed to make, with no window to show it.
    /// A window closing mid-reply interrupts the turn first, as switching
    /// conversations does, so the reply so far is saved; quitting can't
    /// wait for that and ends the process at once.
    func close(appIsQuitting: Bool = false) {
        // A closed window's model must not be found by a delete, which
        // would start a new CLI in a window nobody can see.
        Self.registry.remove(self)
        WorkingConversations.shared.remove(window: self)
        if let cli {
            if appIsQuitting { cli.terminateNow() }
            Self.trackExiting(cli, for: sessionID)
        }
        cli = nil
        failedSessionLoad = nil
        isReady = false
        outstandingTurns = 0
        queuedMessages = []
        queueIsPaused = false
        editingQueuedMessageID = nil
        queuedEditingText = nil
        permissions.clear()
    }

    /// Interrupts every reply underway in every window and waits for those
    /// turns to end, so quitting keeps what Claude wrote so far.
    static func interruptRepliesBeforeQuitting() async {
        let clis = openModels.filter(\.isWorking).compactMap(\.cli)
        await withTaskGroup(of: Void.self) { group in
            for cli in clis { group.addTask { await cli.interruptRunningTurn() } }
        }
    }

    /// Stops this window's CLI and waits until it has exited, so it can't
    /// write its session file again (before that file is deleted).
    func stopAndWait() async {
        guard let cli else { return }
        self.cli = nil
        isReady = false
        await cli.stopAndWait()
    }

    /// Reads this folder's conversations, which is quick, then every
    /// project's, which can take seconds the first time (titles are read
    /// from each file once and kept).
    /// How long after a new conversation starts to look for it again: the
    /// CLI names the session before it has written the prompt, and a file
    /// with no prompt isn't listed, so the sidebar missed a new conversation
    /// (and its working dot) until the turn ended.
    static let newConversationListingDelay: Duration = .seconds(1)

    private func listWhenSaved(_ id: String) {
        Task {
            try? await Task.sleep(for: Self.newConversationListingDelay)
            guard sessionID == id, !sessions.contains(where: { $0.id == id }) else { return }
            refreshSessions()
        }
    }

    /// Tells the sidebar's dots what this window is working on.
    private func reportWorking() {
        WorkingConversations.shared.update(window: self, sessionID: sessionID, working: isWorking, waiting: pendingPermission != nil)
    }

    /// Lines the folder's uncommitted changes add and remove, for the
    /// toolbar's changes button; nil outside a git repository or until known.
    private(set) var changeCounts: ChangeCounts?

    /// Counted again with the conversation list: when the folder changes
    /// and when a turn ends, after Claude may have edited files.
    /// The folder's checked-out branch, for the header; nil outside a
    /// repository or until known.
    private(set) var branch: String?

    private func refreshChangeCounts() {
        guard let directory = workingDirectory else {
            changeCounts = nil
            branch = nil
            return
        }
        Task {
            let set = try? await GitChanges.load(in: directory)
            guard workingDirectory == directory else { return }
            changeCounts = set.flatMap(ChangeCounts.init)
            branch = set?.branch
        }
    }

    func refreshSessions() {
        refreshChangeCounts()
        if let directory = workingDirectory {
            Task {
                let found = await Task.detached { SessionHistory.listSessions(cwd: directory) }.value
                guard workingDirectory == directory else { return }
                sessions = found
                nameForkIfSaved()
            }
        }
        Task {
            listedProjects = await Task.detached { SessionHistory.listProjects() }.value
            mergeProjects()
        }
    }

    /// Retitles a fork once the CLI has saved it, then lists it again.
    private func nameForkIfSaved() {
        guard let title = pendingForkTitle, let fork = sessions.first(where: { $0.id == sessionID }) else { return }
        pendingForkTitle = nil
        do {
            try SessionHistory.rename(fork, to: title)
            refreshSessions()
        } catch {
            Announcer.announce(SessionHistory.ChangeError.renameFailureWording(error), urgency: .urgent)
        }
    }

    private func mergeProjects() {
        projects = SessionHistory.projects(listedProjects, current: workingDirectory, sessions: sessions)
    }

    func send(_ text: String, images: [ImageAttachment] = []) {
        let message = QueuedMessage(text: text, images: images)
        guard !message.isEmpty, canSend else { return }
        if !isReady {
            // Claude ended: start it again; the message goes once it's ready.
            queuedMessages.append(message)
            resumeQueuedMessages()
            return
        }
        guard cli != nil else { return }
        if isWorking || !queuedMessages.isEmpty {
            queuedMessages.append(message)
            // Behind a pause it waits for Resume, which nothing else says.
            Announcer.announce(queueIsPaused ? "Message queued. The queue is paused; Resume sends it." : "Message queued.")
            dispatchNextQueuedMessage()
        } else {
            dispatch(message)
        }
    }

    func beginEditingQueuedMessage(_ id: UUID) {
        guard let message = queuedMessages.first(where: { $0.id == id }) else { return }
        editingQueuedMessageID = id
        queuedEditingText = message.text
    }

    func updateQueuedMessageDraft(_ id: UUID, text: String) {
        guard editingQueuedMessageID == id else { return }
        queuedEditingText = text
    }

    func cancelEditingQueuedMessage() {
        editingQueuedMessageID = nil
        queuedEditingText = nil
        dispatchNextQueuedMessage()
    }

    func updateQueuedMessage(_ id: UUID, text: String) {
        guard let index = queuedMessages.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !queuedMessages[index].images.isEmpty else { return }
        queuedMessages[index].text = trimmed
        if editingQueuedMessageID == id {
            editingQueuedMessageID = nil
            queuedEditingText = nil
        }
        dispatchNextQueuedMessage()
    }

    func cancelQueuedMessage(_ id: UUID) {
        queuedMessages.removeAll { $0.id == id }
        if editingQueuedMessageID == id {
            editingQueuedMessageID = nil
            queuedEditingText = nil
        }
        if queuedMessages.isEmpty { queueIsPaused = false }
        dispatchNextQueuedMessage()
    }

    func resumeQueuedMessages() {
        guard !isWorking else { return }
        queueIsPaused = false
        if canRetrySessionLoad {
            retrySessionLoad()
            return
        }
        if pendingEffortRestart {
            applyEffort()
            return
        }
        if isReady {
            dispatchNextQueuedMessage()
        } else if let directory = workingDirectory {
            let saved = sessionID.flatMap { id in
                sessions.first { $0.id == id } ?? SessionHistory.listSessions(cwd: directory).first { $0.id == id }
            }
            guard sessionID == nil || saved != nil else {
                queueIsPaused = true
                launchError = "Couldn't reopen this session. Open it from the sidebar to reconnect."
                return
            }
            if saved == nil, let source = forkedFrom {
                start(in: directory, resuming: source, fork: true, preservingQueue: true)
            } else {
                start(in: directory, resuming: saved, preservingQueue: true)
            }
        }
    }

    /// Whether a held message will go out as soon as the current turn
    /// ends: the same rule dispatchNextQueuedMessage() applies.
    private var queuedMessageGoesNext: Bool {
        guard !queueIsPaused, !pendingEffortRestart, let first = queuedMessages.first else { return false }
        return first.id != editingQueuedMessageID
    }

    private func dispatchNextQueuedMessage() {
        guard isReady, !isWorking, !queueIsPaused, pendingPermission == nil,
              !pendingEffortRestart, let first = queuedMessages.first,
              first.id != editingQueuedMessageID else { return }
        dispatch(queuedMessages.removeFirst())
    }

    private func dispatch(_ message: QueuedMessage) {
        guard let cli else { return }
        let attemptID = UUID().uuidString
        liveTranscript.appendUser(message.transcriptText, id: attemptID)
        publishTranscript()
        outstandingTurns += 1
        soundCues.messageSent()
        Task {
            do {
                // The row's id, so the row read back from the file has it too.
                try await cli.send(message.text, images: message.images, uuid: attemptID)
            } catch {
                guard self.cli === cli else { return }
                launchError = error.localizedDescription
                liveTranscript.markUserUnsent(id: attemptID)
                publishTranscript()
                queuedMessages.insert(message, at: 0)
                queueIsPaused = true
                isReady = false
                outstandingTurns = max(0, outstandingTurns - 1)
                soundCues.sendFailed()
            }
        }
    }

    /// The pending request's questions when Claude is asking the user to
    /// choose, rather than asking to run a tool.
    var pendingQuestions: [UserQuestion]? {
        pendingPermission.flatMap(AskUserQuestion.questions(in:))
    }

    func answerQuestions(_ answers: [String: [String]], for requestID: String? = nil) {
        guard let request = pendingPermission, let cli, requestID.map({ $0 == request.requestID }) ?? true else { return }
        permissions.resolve(request.requestID)
        let input = AskUserQuestion.answering(request, with: answers)
        markAnswered(request)
        Task { try? await cli.answer(request, allow: true, updatedInput: input) }
    }

    /// Answers the request on screen. `remember` allows it and asks the CLI
    /// to keep the rule it offered. Given `requestID`, only while that's
    /// still the request on screen: a second press meant for one answered
    /// the next, which hadn't been read out.
    func answerPermission(allow: Bool, remember: PermissionSuggestion? = nil, denialMessage: String? = nil, for requestID: String? = nil) {
        guard let request = pendingPermission, let cli, requestID.map({ $0 == request.requestID }) ?? true else { return }
        permissions.resolve(request.requestID)
        if let mode = remember?.raw["mode"]?.string, remember?.raw["type"]?.string == "setMode" {
            permissionMode = mode
        }
        markAnswered(request)
        if !allow {
            soundCues.userDenied(toolUseID: request.toolUseID)
            if !liveTranscript.markDenied(toolUseID: request.toolUseID).isEmpty { publishTranscript() }
        }
        Task { try? await cli.answer(request, allow: allow, remember: remember, denialMessage: denialMessage) }
    }

    /// The tool's row stops waiting on the user as soon as they answer.
    private func markAnswered(_ request: PermissionRequest) {
        guard !liveTranscript.permissionAnswered(toolUseID: request.toolUseID).isEmpty else { return }
        publishTranscript()
    }

    private func control(_ action: @escaping @Sendable (ClaudeCLI) async throws -> Void) {
        guard let cli else { return }
        Task {
            do {
                try await action(cli)
            } catch {
                launchError = error.localizedDescription
            }
        }
    }

    func interrupt() {
        guard let cli else { return }
        // Only a stop that ends a turn may hush that turn's failures.
        if isWorking { soundCues.userStopped() }
        queueIsPaused = !queuedMessages.isEmpty
        Task { try? await cli.interrupt() }
    }

    /// For the side chat, which has no sheet to ask in: every permission
    /// request and question is declined as it arrives.
    @ObservationIgnored var declinesPermissions = false
    static let sideChatDenial = "This is a side chat, which can't run tools, change files or ask questions. Answer from what you can read."

    /// Plays a sound cue; tests listen here.
    @ObservationIgnored var playCue: (SoundCue) -> Void = { SoundCuePlayer.shared.play($0) }
    @ObservationIgnored private var activityAnnouncements = ActivityAnnouncements()
    /// Posts and withdraws notifications; tests listen here.
    @ObservationIgnored var postNotification: (_ id: String, _ title: String, _ body: String) -> Void = { Notifier.notify(id: $0, title: $1, body: $2) }
    @ObservationIgnored var withdrawNotifications: ([String]) -> Void = { Notifier.withdraw($0) }
    /// Keeps this window's notification ids apart from another window's.
    @ObservationIgnored private let notificationScope = UUID().uuidString

    func permissionNotificationID(_ requestID: String) -> String { "\(notificationScope).permission.\(requestID)" }
    /// One per window: a newer reply's replaces the last.
    var finishedNotificationID: String { "\(notificationScope).finished" }

    private func handle(_ event: StreamEvent) {
        var dispatchQueuedAfterEvent = false
        var finishedCleanly = false
        let cuesOn = UserDefaults.standard.bool(forKey: SoundCuePolicy.defaultsKey)
        for cue in soundCues.cues(for: event, at: ProcessInfo.processInfo.systemUptime, enabled: cuesOn,
                                  moreToSend: queuedMessageGoesNext) {
            playCue(cue)
        }
        // Worked out whatever the setting, so turning it on mid-turn
        // doesn't repeat a step already in progress.
        if let spoken = activityAnnouncements.spoken(for: event),
           UserDefaults.standard.bool(forKey: ActivityAnnouncements.defaultsKey) {
            Announcer.announce(spoken)
        }
        switch event {
        case .permissionRequest(let request) where declinesPermissions:
            // Nowhere to ask: declined at once, with why, so Claude goes on.
            permissions.enqueue(request)
            answerPermission(allow: false, denialMessage: Self.sideChatDenial, for: request.requestID)
        case .permissionRequest(let request):
            permissions.enqueue(request)
            postNotification(permissionNotificationID(request.requestID), "Claude needs your permission",
                             ToolSummary.describe(name: request.toolName, input: request.input))
        case .permissionCancelled(let requestID):
            // Answering a withdrawn request would reach a CLI that no
            // longer waits for it; the prompt just goes away.
            _ = permissions.resolve(requestID)
        case .usageLimits(let limits):
            usageLimits = limits
        case .contextUsage(let usage):
            contextUsage = usage
        case .initialized(let info):
            models = info.models
            commands = info.commands
            if let mode = info.permissionMode { takeModeFromCLI(mode) }
        case .permissionModeReported(let mode):
            takeModeFromCLI(mode)
        case .sessionStarted(let id, _):
            if sessionID != id {
                sessionID = id
                // A fork with its own id now restarts as itself.
                forkedFrom = nil
                refreshSessions()
                listWhenSaved(id)
            }
        case .turnStopped:
            // Pending local messages wait for an explicit resume after Stop.
            outstandingTurns = 0
            queueIsPaused = !queuedMessages.isEmpty
            permissions.clearTurn()
            Announcer.announce("Stopped.")
            refreshSessions()
            // An effort chosen mid-reply waited for the reply to end, and a
            // stop ends it too; left pending, the next message ran at the
            // old effort while the picker showed the new.
            if pendingEffortRestart {
                launchError = nil
                Task { @MainActor in self.applyEffort() }
            }
        case .processExited:
            // Said once the events run out ("Claude stopped running…"); an
            // error announced here too was cut off by it.
            outstandingTurns = 0
            permissions.clear()
        case .turnFinished(let isError, let summary):
            outstandingTurns = max(0, outstandingTurns - 1)
            if isError { queueIsPaused = !queuedMessages.isEmpty }
            if !isWorking, pendingEffortRestart {
                launchError = nil
                Task { @MainActor in self.applyEffort() }
            } else {
                dispatchQueuedAfterEvent = !isError
            }
            // A prompt still up belongs to a turn that can no longer use it.
            permissions.clearTurn()
            refreshSessions()
            if isError {
                Announcer.announce(summary.map { "Error: \($0)" } ?? "Claude stopped with an error.", urgency: .urgent)
            } else {
                // Said below, once it's known whether a queued message went.
                finishedCleanly = true
            }
        default:
            break
        }
        let changes = liveTranscript.apply(event)
        switch pacing.changed(by: event, changes: changes, at: ProcessInfo.processInfo.systemUptime) {
        case .publishNow:
            publishTranscript()
        case .publishAt(let due):
            pendingPublish = Task { [weak self] in
                let delay = due - ProcessInfo.processInfo.systemUptime
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                self?.publishTranscript()
            }
        case .wait:
            break
        }
        // A reply that ended out of sight is unread. Marked here, as the
        // turn ends, not when the window sees isWorking go false: opening
        // another session mid-turn also ends working, by which time the
        // window already showed the new session.
        if case .turnFinished = event, !isWorking {
            WorkingConversations.shared.finished(sessionID, seen: isSeen)
        }
        if dispatchQueuedAfterEvent { dispatchNextQueuedMessage() }
        // Announced when nothing went next, even with a message waiting
        // while it's edited; it had waited for an empty queue.
        if finishedCleanly, !isWorking {
            if FinishAnnouncement.isOn { Announcer.announce("Claude finished.") }
            postNotification(finishedNotificationID, "Claude finished", lastReplyPreview)
        }
    }

    /// Shows the view the conversation as of now, including any streamed
    /// text still waiting.
    private func publishTranscript() {
        pendingPublish?.cancel()
        pendingPublish = nil
        transcript = liveTranscript
        transcriptRevision += 1
        let start = ProcessInfo.processInfo.systemUptime
        pacing.published(at: start)
        measureUpdateCost(since: start)
    }

    /// SwiftUI lays out and draws the conversation in Core Animation's
    /// commit, which runs just before the main run loop waits. An observer
    /// ordered after that commit sees how long the update kept the main
    /// thread busy, and the pacing spaces streaming updates to suit.
    private func measureUpdateCost(since start: TimeInterval) {
        guard costObserver == nil else { return }
        let made: CFRunLoopObserver? = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
        ) { [weak self] observer, _ in
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.costObserver = nil
                self.pacing.updateCost(ProcessInfo.processInfo.systemUptime - start)
            }
        }
        guard let made else { return }
        costObserver = made
        CFRunLoopAddObserver(CFRunLoopGetMain(), made, .commonModes)
    }
}

/// Speaks short status changes through VoiceOver without moving its cursor.
enum Announcer {
    /// Whether a line may cut off what VoiceOver is saying. Most lines
    /// confirm something the user just did and can wait their turn; only
    /// errors and requests that need an answer interrupt.
    ///
    /// Measured on macOS 27 by recording system audio while VoiceOver read a
    /// long reply and a "Marked." announcement arrived about 4 s in: at
    /// high priority the reading broke off about 2.5 s later, at medium about
    /// 5 s later (2.5 s more of the reply heard), in both cases without
    /// resuming. So medium lets VoiceOver finish what it's in the middle of,
    /// probably the current line, but doesn't wait for the whole reply.
    /// Low priority measured the same as medium, so there is no gentler
    /// level to pick.
    enum Urgency {
        case routine
        case urgent

        var priority: NSAccessibilityPriorityLevel {
            switch self {
            case .routine: .medium
            case .urgent: .high
            }
        }
    }

    /// How long an announcement waits after focus moves, as when a sheet
    /// or dialog closes: VoiceOver first reads where focus landed ("Closing
    /// dialog", then the field), and one posted with the move went unheard
    /// (live).
    static let afterFocusMoveDelay: Duration = .seconds(1)

    /// Announces once VoiceOver has read where focus went.
    @MainActor
    static func announceAfterFocusMove(_ text: String, urgency: Urgency = .routine) {
        Task { @MainActor in
            try? await Task.sleep(for: afterFocusMoveDelay)
            announce(text, urgency: urgency)
        }
    }

    /// Tests listen to see what would be announced, and how urgently. A
    /// list, so suites running in parallel each hear everything without
    /// replacing one another's listener.
    @MainActor private static var listeners: [Int: (String, Urgency) -> Void] = [:]
    @MainActor private static var nextListener = 0

    @MainActor
    static func listen(_ listener: @escaping (String, Urgency) -> Void) -> Int {
        nextListener += 1
        listeners[nextListener] = listener
        return nextListener
    }

    @MainActor
    static func stopListening(_ token: Int) {
        listeners[token] = nil
    }

    @MainActor
    static func announce(_ text: String, urgency: Urgency = .routine) {
        listeners.values.forEach { $0(text, urgency) }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: urgency.priority.rawValue,
            ]
        )
    }
}

/// Which conversations are working in any window, for the sidebar's dots.
/// Each window reports its latest, so finishing, switching conversations
/// or closing clears its mark.
@MainActor
@Observable
final class WorkingConversations {
    static let shared = WorkingConversations(defaults: .standard)
    static let unreadKey = "unreadSessions"

    /// Where unread marks are kept across launches, as pins and archives
    /// are; nil keeps them in memory, for tests.
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let saved = defaults?.string(forKey: Self.unreadKey) {
            unread = Set(saved.split(separator: "\n").map(String.init))
        }
    }

    private(set) var ids: Set<String> = []
    /// Conversations waiting on the user: a tool to allow, a plan, a question.
    private(set) var waiting: Set<String> = []
    /// Conversations that finished a turn while their window wasn't in front.
    private(set) var unread: Set<String> = [] {
        didSet { defaults?.set(unread.sorted().joined(separator: "\n"), forKey: Self.unreadKey) }
    }
    @ObservationIgnored private var byWindow: [ObjectIdentifier: String] = [:]
    @ObservationIgnored private var waitingByWindow: [ObjectIdentifier: String] = [:]

    func update(window: AnyObject, sessionID: String?, working: Bool, waiting isWaiting: Bool = false) {
        byWindow[ObjectIdentifier(window)] = working ? sessionID : nil
        waitingByWindow[ObjectIdentifier(window)] = isWaiting ? sessionID : nil
        refresh()
    }

    func remove(window: AnyObject) {
        byWindow[ObjectIdentifier(window)] = nil
        waitingByWindow[ObjectIdentifier(window)] = nil
        refresh()
    }

    /// A turn ended; unread unless the user was looking at it.
    func finished(_ sessionID: String?, seen: Bool) {
        guard let sessionID, !seen else { return }
        unread.insert(sessionID)
    }

    /// Mark as Unread, to come back to it: the mark stays until the
    /// session is next looked at.
    func markUnread(_ sessionID: String) {
        unread.insert(sessionID)
    }

    /// The user is looking at the conversation now.
    func seen(_ sessionID: String?) {
        guard let sessionID, unread.contains(sessionID) else { return }
        unread.remove(sessionID)
    }

    private func refresh() {
        let current = Set(byWindow.values)
        if current != ids { ids = current }
        let asking = Set(waitingByWindow.values)
        if asking != waiting { waiting = asking }
    }
}
