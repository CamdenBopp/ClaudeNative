import ClaudeNativeCore
import SwiftUI

/// Command-K's palette, as the Claude app's: "Search or start a session".
/// The keyboard stays in the field, as in the slash command list: Up and
/// Down move the highlight and VoiceOver hears each highlighted session,
/// Return opens it, and with nothing matching Return starts a new session
/// with what was typed. Escape closes it.
struct SessionPalette: View {
    let projects: [SessionHistory.ProjectSummary]
    /// Opens a saved session in its folder.
    let open: (SessionHistory.ProjectSummary, SessionHistory.SessionSummary) -> Void
    /// Starts a new session in the window's folder with this text.
    let start: (String) -> Void
    @State private var query = ""
    /// The highlighted session, by id; nil is the first. A place in the
    /// list moved under it when a finished reply reordered the sessions,
    /// and Return opened a different one from the one VoiceOver had read.
    @State private var highlightedID: String?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    struct Match: Identifiable {
        let project: SessionHistory.ProjectSummary
        let session: SessionHistory.SessionSummary
        var id: String { session.id }
    }

    /// Every project's sessions that match, best fit first (the title
    /// before the first prompt), then newest, at most
    /// `PaletteLayout.maxResults`. Return opens the first.
    var matches: [Match] {
        Self.ranked(projects, query: query)
    }

    static func ranked(_ projects: [SessionHistory.ProjectSummary], query: String) -> [Match] {
        let found: [Match] = projects.flatMap { project in project.sessions.map { Match(project: project, session: $0) } }
            .filter { ConversationSearch.matches($0.session, query: query) }
        let all = found.sorted { first, second in
            let firstFit = ConversationSearch.relevance(first.session, query: query)
            let secondFit = ConversationSearch.relevance(second.session, query: query)
            if firstFit != secondFit { return firstFit > secondFit }
            return first.session.lastModified > second.session.lastModified
        }
        return Array(all.prefix(PaletteLayout.maxResults))
    }

    static func spoken(_ match: Match) -> String {
        "\(SavedConversationList.spokenRow(match.session)), in \(match.project.name)"
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let shown = matches
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            TextField("Search or start a session", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                // Named, not only by its placeholder, so it's named while
                // something is typed too.
                .accessibilityLabel("Search or start a session")
                .focused($fieldFocused)
                .onKeyPress(.downArrow) { move(1, in: shown) }
                .onKeyPress(.upArrow) { move(-1, in: shown) }
                .onSubmit { choose(in: shown) }
                .onChange(of: query) { highlightedID = nil }
            if shown.isEmpty {
                Text(trimmed.isEmpty ? "No saved sessions yet." : "Return starts a new session: \u{201C}\(trimmed)\u{201D}")
                    .foregroundStyle(Color(nsColor: .labelColor))
            } else {
                let highlighted = shown.firstIndex { $0.id == highlightedID } ?? (highlightedID == nil ? 0 : -1)
                ScrollViewReader { proxy in
                    List(Array(shown.enumerated()), id: \.element.id) { index, match in
                        HStack {
                            Text(match.session.title).lineLimit(1)
                            Spacer()
                            Text(match.project.name)
                                .foregroundStyle(Color(nsColor: Theme.quietLabel))
                                .lineLimit(1)
                        }
                        .padding(.vertical, Theme.Spacing.xSmall)
                        .listRowBackground(index == highlighted ? PickerRowHighlight.shape : nil)
                        .contentShape(Rectangle())
                        .onTapGesture { open(match) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Self.spoken(match))
                        .accessibilityAddTraits(index == highlighted ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { open(match) }
                        .id(match.id)
                    }
                    .onChange(of: highlightedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                    .onChange(of: query) {
                        // A new search selects the first result again.
                        // Keep that result visible even when the matching
                        // rows stay the same and the list keeps its scroll.
                        if let first = shown.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
                .frame(minHeight: PaletteLayout.listMinHeight)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(minWidth: PaletteLayout.minWidth)
        .onAppear { fieldFocused = true }
        // Said once typing settles, after the slash list's longer pause:
        // half a second in, VoiceOver's echo of the typing won (live).
        .task(id: highlightedID == nil ? query : nil) {
            // An arrow key has already named the selected session. The
            // delayed first-result summary must not contradict that choice.
            guard highlightedID == nil else { return }
            guard (try? await Task.sleep(for: SlashCommandSearch.announcementDelay)) != nil else { return }
            let found = matches
            let first = found.first.map { " " + Self.spoken($0) + "." } ?? ""
            let wording = found.isEmpty && !trimmed.isEmpty
                ? "No sessions match. Return starts a new session."
                : ConversationSearch.resultCountWording(found.count) + first
            Announcer.announce(wording, urgency: .urgent)
        }
    }

    /// The session `step` places from `id` (nil: the first), wrapping.
    static func stepped(from id: String?, by step: Int, in shown: [Match]) -> String? {
        guard !shown.isEmpty else { return nil }
        let current = shown.firstIndex { $0.id == id } ?? 0
        return shown[(current + step + shown.count) % shown.count].id
    }

    /// What Return opens: the highlighted session wherever it now is, the
    /// first when nothing was highlighted, nothing if it left the list.
    static func chosen(_ id: String?, in shown: [Match]) -> Match? {
        guard let id else { return shown.first }
        return shown.first { $0.id == id }
    }

    private func move(_ step: Int, in shown: [Match]) -> KeyPress.Result {
        guard let id = Self.stepped(from: highlightedID, by: step, in: shown),
              let match = shown.first(where: { $0.id == id }) else { return .ignored }
        highlightedID = id
        Announcer.announce(Self.spoken(match), urgency: .urgent)
        return .handled
    }

    private func choose(in shown: [Match]) {
        if let match = Self.chosen(highlightedID, in: shown) {
            open(match)
        } else if highlightedID != nil {
            Announcer.announce("That session is no longer listed.", urgency: .urgent)
        } else if !trimmed.isEmpty {
            dismiss()
            start(trimmed)
        }
    }

    private func open(_ match: Match) {
        dismiss()
        open(match.project, match.session)
    }
}

enum PaletteLayout {
    static let minWidth: CGFloat = 520
    static let listMinHeight: CGFloat = 300
    /// Enough to scan; more is what typing a word is for.
    static let maxResults = 50
}
