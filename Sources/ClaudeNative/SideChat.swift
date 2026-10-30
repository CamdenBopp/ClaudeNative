import ClaudeNativeCore
import SwiftUI

/// The side panel's side chat, as the Claude app's: a quick question in a
/// session of its own, in the same folder, that leaves the main session
/// alone. It runs in Plan mode, so Claude can read the project but not
/// change it. Its prompts would have nowhere to show, since the window's
/// sheets belong to the main session, so its model declines each one as it
/// arrives (Plan mode still asks before some commands and questions).
struct SideChatView: View {
    let chat: AppModel
    let folder: URL?
    var focusToken = 0
    /// Bumped each time the panel opens on the side chat (Command-;). The
    /// view stays alive between opens, so its onAppear ran only the first
    /// time and a second Command-; left focus where it was.
    var openRequest = 0
    @State private var draft = ""
    @State private var attachments: [ImageAttachment] = []
    @FocusState private var fieldFocused: Bool
    @State private var navigator = MessageNavigator()

    var body: some View {
        VStack(spacing: 0) {
            if chat.transcript.entries.isEmpty {
                EmptyState("Side Chat", systemImage: "bubble.left.and.bubble.right", description: "Ask a quick question. Your session stays as it is.")
                    .frame(maxHeight: .infinity)
            } else {
                TranscriptView(
                    transcript: chat.transcript,
                    revision: chat.transcriptRevision,
                    workingDirectory: chat.workingDirectory,
                    isWorking: chat.isWorking,
                    sessionID: chat.sessionID,
                    navigator: navigator
                )
            }
            if let error = chat.launchError {
                Text(error)
                    .foregroundStyle(Color(nsColor: Theme.errorText))
                    .padding(Theme.Spacing.small)
            }
            if !chat.queuedMessages.isEmpty {
                QueuedMessagesView(model: chat, interactionEnded: { fieldFocused = true })
            }
            Composer(
                draft: $draft,
                attachments: $attachments,
                focus: $fieldFocused,
                isReady: chat.canSend,
                isWorking: chat.isWorking,
                usageLimits: nil,
                contextUsage: nil,
                send: {
                    guard chat.canSend else { return }
                    chat.send(draft)
                    draft = ""
                },
                stop: { chat.interrupt() },
                attachImages: {},
                placeholder: "Ask a quick question\u{2026}"
            )
        }
        // Go > Previous and Next Message move through the side chat while
        // focus is in it; the window's navigator, for the main session,
        // took them there before.
        .focusedValue(\.messageNavigator, navigator)
        .onAppear {
            start()
            // Once the panel is on screen: set while it was still coming
            // in, the keyboard moved but VoiceOver's cursor stayed on the
            // main message field (live).
            Task { @MainActor in
                try? await Task.sleep(for: SidePanelLayout.appearanceDuration)
                fieldFocused = true
            }
        }
        .onChange(of: folder) { start() }
        // Kept out of the sidebar's list once it has a session.
        .onChange(of: chat.sessionID) { _, id in
            if let id { SideChats.remember(id) }
        }
        .onChange(of: focusToken) { fieldFocused = true }
        .onChange(of: openRequest) { fieldFocused = true }
    }

    private func start() {
        guard let folder, chat.workingDirectory.map(SessionHistory.canonicalPath) != SessionHistory.canonicalPath(folder) else { return }
        chat.permissionModeChoice = "plan"
        chat.start(in: folder)
    }
}

/// Which sessions are side chats, so the sidebar leaves them out.
enum SideChats {
    static let defaultsKey = "sideChatSessions"

    static func ids(in defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.string(forKey: defaultsKey) ?? "").split(separator: "\n").map(String.init))
    }

    static func remember(_ id: String, in defaults: UserDefaults = .standard) {
        var ids = ids(in: defaults)
        guard ids.insert(id).inserted else { return }
        defaults.set(ids.sorted().joined(separator: "\n"), forKey: defaultsKey)
    }

    /// `projects` without the side chats' sessions; a project left with
    /// none keeps its heading, as an empty project does.
    static func hiding(_ projects: [SessionHistory.ProjectSummary], ids: Set<String>) -> [SessionHistory.ProjectSummary] {
        guard !ids.isEmpty else { return projects }
        return projects.map { project in
            SessionHistory.ProjectSummary(
                directory: project.directory, name: project.name,
                sessions: project.sessions.filter { !ids.contains($0.id) },
                startsConversations: project.startsConversations
            )
        }
    }
}
