import ClaudeNativeCore
import SwiftUI

/// What the Session menu can do in the focused window.
struct SessionMenuActions {
    let search: () -> Void
    let chooseMode: () -> Void
    let chooseModel: () -> Void
    /// Nil when the model has no effort levels.
    let chooseEffort: (() -> Void)?
    /// Nil until the session is saved: a new one can't be renamed or pinned.
    let rename: (() -> Void)?
    let togglePin: (() -> Void)?
    let toggleArchive: (() -> Void)?
    let toggleUnread: (() -> Void)?
    let isUnread: Bool
    /// Nil while Claude works, or before the session is saved.
    let fork: (() -> Void)?
    let isArchived: Bool
    let isPinned: Bool
}

/// Archived sessions, kept as ids, one per line: left out of the sidebar
/// unless Show Archived Sessions is on.
enum SessionArchive {
    static let defaultsKey = "archivedSessions"
    static let showKey = "showArchivedSessions"

    static func ids(in store: String) -> Set<String> {
        Set(store.split(separator: "\n").map(String.init))
    }

    static func ids(in defaults: UserDefaults = .standard) -> Set<String> {
        ids(in: defaults.string(forKey: defaultsKey) ?? "")
    }
}

/// The sessions Command-1 to Command-9 open, by title, in the sidebar's
/// order.
struct SessionJumps {
    let sessions: [(title: String, open: () -> Void)]
}

extension FocusedValues {
    @Entry var sessionMenu: SessionMenuActions?
    @Entry var sessionJumps: SessionJumps?
}

/// The Session menu: the Claude app's keys for the open session, where
/// VoiceOver's menu bar (VO-M) and the Help menu's search can find them.
struct SessionCommands: Commands {
    @FocusedValue(\.sessionMenu) private var session
    @FocusedValue(\.sessionJumps) private var jumps
    @AppStorage(SessionArchive.showKey) private var showArchived = false
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Session") {
            // Command-K, as in the Claude app.
            Button("Search or Start a Session…") { session?.search() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(session == nil)
            Divider()
            Button("Choose Mode…") { session?.chooseMode() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Choose Model…") { session?.chooseModel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(session == nil)
            // Shift-Command-E, as in the Claude app.
            Button("Choose Effort…") { session?.chooseEffort?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(session?.chooseEffort == nil)
            Divider()
            Button("Rename Session…") { session?.rename?() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(session?.rename == nil)
            Button(session?.isPinned == true ? "Unpin Session" : "Pin Session") { session?.togglePin?() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(session?.togglePin == nil)
            // Option-Command-A, as in the Claude app.
            Button(session?.isArchived == true ? "Unarchive Session" : "Archive Session") { session?.toggleArchive?() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(session?.toggleArchive == nil)
            // Shift-Command-T, as in the Claude app. Not tied to a window:
            // it works after the last one closes, as it does in a browser.
            Button("Reopen Closed Session") { ClosedSessions.reopenLast(with: openWindow) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(ClosedSessions.shared.isEmpty)
            // Option-Command-O, as in the Claude app.
            Button("Fork Session") { session?.fork?() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(session?.fork == nil)
            // Option-Command-U, as in the Claude app.
            Button(session?.isUnread == true ? "Mark as Read" : "Mark as Unread") { session?.toggleUnread?() }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(session?.toggleUnread == nil)
            Toggle("Show Archived Sessions", isOn: $showArchived)
            Divider()
            // Command and a number, as the Claude app jumps to a session.
            // Titled by the sessions, so the menu says where each goes.
            Menu("Go to Session") {
                ForEach(Array((jumps?.sessions ?? []).enumerated()), id: \.offset) { number, jump in
                    Button(jump.title, action: jump.open)
                        .keyboardShortcut(KeyEquivalent(Character(String(number + 1))), modifiers: .command)
                }
            }
            .disabled(jumps?.sessions.isEmpty ?? true)
        }
    }
}

/// Hands a session to the window Open in New Window opens, which takes it
/// as it starts instead of its stored folder.
@MainActor
enum NewWindowSession {
    static let windowID = "session"
    static var pending: (URL, SessionHistory.SessionSummary)?

    static func take() -> (URL, SessionHistory.SessionSummary)? {
        defer { pending = nil }
        return pending
    }
}

/// Sessions whose windows closed, newest last, for Reopen Closed Session.
@MainActor @Observable
final class ClosedSessions {
    static let shared = ClosedSessions()
    /// Enough to undo a run of closes; older ones are in the sidebar.
    static let limit = 20
    private var closed: [(directory: URL, session: SessionHistory.SessionSummary)] = []

    var isEmpty: Bool { closed.isEmpty }

    func remember(_ directory: URL, _ session: SessionHistory.SessionSummary) {
        closed.removeAll { $0.session.id == session.id }
        closed.append((directory, session))
        if closed.count > Self.limit { closed.removeFirst(closed.count - Self.limit) }
    }

    /// Session > Reopen Closed Session: the last window closed on a saved
    /// session, in a new window, as Shift-Command-T reopens a tab. One open
    /// again elsewhere since is skipped, as Open in New Window won't open a
    /// session twice, and so is one deleted since.
    static func reopenLast(with openWindow: OpenWindowAction) {
        if let (directory, session) = shared.takeLastReopenable(
            isOpen: { !AppModel.models(showing: $0).isEmpty }, isBeingDeleted: AppModel.isBeingDeleted
        ) {
            NewWindowSession.pending = (directory, session)
            openWindow(id: NewWindowSession.windowID)
            return
        }
        Announcer.announce("No closed session to reopen.")
    }

    func takeLast() -> (URL, SessionHistory.SessionSummary)? {
        closed.popLast().map { ($0.directory, $0.session) }
    }

    /// The last closed session that can still be opened: its file still
    /// there, not being deleted, and not open in a window again. Ones that
    /// can't are passed over and forgotten. A deleted session was reopened,
    /// from the Trash: "Couldn't read that session", then a failed resume.
    func takeLastReopenable(isOpen: (String) -> Bool, isBeingDeleted: (String) -> Bool) -> (URL, SessionHistory.SessionSummary)? {
        while let (directory, session) = takeLast() {
            guard FileManager.default.fileExists(atPath: session.fileURL.path),
                  !isBeingDeleted(session.id), !isOpen(session.id) else { continue }
            return (directory, session)
        }
        return nil
    }
}
