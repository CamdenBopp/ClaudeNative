import ClaudeNativeCore
import SwiftUI

/// What /projects shows: every project, newest first, as the sidebar lists
/// them. Return (or a double-click) starts a new conversation in the
/// highlighted one; Escape closes the list.
struct ProjectsSheet: View {
    let projects: [SessionHistory.ProjectSummary]
    let choose: (SessionHistory.ProjectSummary) -> Void
    @State private var selection: String?
    @FocusState private var listFocused: Bool
    @Environment(\.dismiss) private var dismiss

    /// The projects /projects lists: ones a session can start in, counted
    /// as the sidebar shows them, without side chats, and without archived
    /// sessions unless Show Archived Sessions is on.
    static func listed(_ projects: [SessionHistory.ProjectSummary], in defaults: UserDefaults = .standard) -> [SessionHistory.ProjectSummary] {
        let archived = defaults.bool(forKey: SessionArchive.showKey) ? [] : SessionArchive.ids(in: defaults)
        return SideChats.hiding(projects.filter(\.startsConversations), ids: SideChats.ids(in: defaults).union(archived))
    }

    private var chosen: SessionHistory.ProjectSummary? { projects.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Projects")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if projects.isEmpty {
                Text("No projects yet. Open a folder with Shift-Command-O to start one.")
                    .foregroundStyle(.primary)
            } else {
                List(projects, selection: $selection) { project in
                    Text(project.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // One element per project: its name, and how many
                        // conversations it has.
                        .accessibilityLabel("\(project.name), \(ProjectsWording.count(project.sessions.count))")
                        .tag(project.id)
                }
                .focused($listFocused)
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                    guard let id = ids.first, let project = projects.first(where: { $0.id == id }) else { return }
                    start(project)
                }
                .frame(minHeight: ProjectsLayout.listMinHeight)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("New Session") { chosen.map(start) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(minWidth: ProjectsLayout.minWidth)
        .onAppear {
            selection = projects.first?.id
            listFocused = true
        }
        // Focus arriving in the list was heard as just "table" (live), so
        // the count and the highlighted project are said.
        .task {
            guard (try? await Task.sleep(for: Theme.accessibilityFocusDelay)) != nil else { return }
            Announcer.announce(ProjectsWording.opening(projects), urgency: .urgent)
        }
    }

    private func start(_ project: SessionHistory.ProjectSummary) {
        dismiss()
        choose(project)
        // Once the sheet has closed: said with the move, it went unheard.
        Announcer.announceAfterFocusMove(ProjectsWording.started(project))
    }
}

enum ProjectsWording {
    /// "12 projects. compiler, 20 conversations."
    static func opening(_ projects: [SessionHistory.ProjectSummary]) -> String {
        guard let first = projects.first else { return "No projects yet." }
        let count = projects.count == 1 ? "1 project" : "\(projects.count) projects"
        return "\(count). \(first.name), \(self.count(first.sessions.count))."
    }

    /// "New session in compiler."
    static func started(_ project: SessionHistory.ProjectSummary) -> String {
        "New session in \(project.name)."
    }

    static func count(_ conversations: Int) -> String {
        conversations == 1 ? "1 session" : "\(conversations) sessions"
    }
}

enum ProjectsLayout {
    /// Room for a long folder name beside the sheet's buttons.
    static let minWidth: CGFloat = 420
    /// About ten projects at once before the list scrolls.
    static let listMinHeight: CGFloat = 260
}
