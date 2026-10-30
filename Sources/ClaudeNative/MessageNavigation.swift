import AppKit
import ClaudeNativeCore
import SwiftUI

/// Carries the Go menu's moves to the conversation on screen. The
/// conversation's coordinator registers itself here; the menu only knows
/// this object, through the focused scene.
@MainActor
final class MessageNavigator {
    weak var coordinator: TranscriptView.Coordinator?

    func perform(_ move: TranscriptNavigation.MessageMove) {
        coordinator?.moveMessage(move)
    }
}

extension FocusedValues {
    /// The focused window's conversation, while it has one.
    @Entry var messageNavigator: MessageNavigator?
}

/// Go > Previous Message, Next Message and Go to Latest Message, as
/// Preview's Go menu moves between pages. Each scrolls the message to the
/// top of the conversation and moves VoiceOver to it.
///
/// Command-Control-Up and Command-Control-Down, as in Neon. Control-Up and
/// Control-Down alone belong to Mission Control and App Exposé, and
/// Control-Option is VoiceOver's, so neither is used. Command-Control-End
/// (Fn-Command-Control-Right on a laptop) goes to the latest, as End goes
/// to the bottom of a document.
struct MessageNavigationCommands: Commands {
    @FocusedValue(\.messageNavigator) private var navigator
    @FocusedValue(\.projectNavigator) private var projects
    @FocusedValue(\.focusMessageField) private var messageField

    var body: some Commands {
        CommandMenu("Go") {
            Button("Previous Message") { navigator?.perform(.previous) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(navigator == nil)
            Button("Next Message") { navigator?.perform(.next) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(navigator == nil)
            Button("Go to Latest Message") { navigator?.perform(.latest) }
                .keyboardShortcut(.end, modifiers: [.command, .control])
                .disabled(navigator == nil)
            // Option-Command and the arrows, as the Claude app jumps
            // between your prompts.
            Button("Previous Prompt") { navigator?.perform(.previousPrompt) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(navigator == nil)
            Button("Next Prompt") { navigator?.perform(.nextPrompt) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(navigator == nil)
            // Command-L, as browsers jump to their address field.
            Button("Go to Message Field") { messageField?.run() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(messageField == nil)
            Divider()
            // Shift-Option-Command and the arrows: Option-Command alone
            // moves between prompts, as in the Claude app.
            Button("Previous Project") { projects?.perform(.previous) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
                .disabled(projects == nil)
            Button("Next Project") { projects?.perform(.next) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
                .disabled(projects == nil)
        }
    }
}

/// Carries Go > Next Project and Previous Project to the sidebar. VoiceOver's
/// heading keys can't reach a project scrolled out of the sidebar's view
/// (SwiftUI's list leaves off-screen rows without live elements), so these
/// scroll to the project and move VoiceOver to its heading.
@MainActor @Observable
final class ProjectNavigator {
    enum Direction { case next, previous }
    /// The latest move asked for; the count makes a repeat a change.
    private(set) var request: (direction: Direction, count: Int)?

    func perform(_ direction: Direction) {
        request = (direction, (request?.count ?? 0) + 1)
    }
}

extension FocusedValues {
    /// The focused window's sidebar.
    @Entry var projectNavigator: ProjectNavigator?
}

/// Go > Go to Message Field: puts keyboard focus, and so VoiceOver, in the
/// window's message field from anywhere in the window.
struct FocusMessageFieldAction {
    let run: () -> Void
}

extension FocusedValues {
    @Entry var focusMessageField: FocusMessageFieldAction?
}

/// Carries the toolbar title's menu (Rename, Pin, Delete) to the sidebar,
/// which holds the rename sheet, the delete confirmation and the pins, so
/// the header and a row's menu do the same thing.
@MainActor @Observable
final class SessionActions {
    enum Action { case rename, togglePin, toggleArchive, toggleUnread, delete }
    /// The latest request, for a conversation by id; the count makes a
    /// repeat a change.
    private(set) var request: (action: Action, sessionID: String, count: Int)?

    func perform(_ action: Action, on sessionID: String) {
        request = (action, sessionID, (request?.count ?? 0) + 1)
    }
}
