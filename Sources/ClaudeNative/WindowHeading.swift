import SwiftUI

/// The conversation's title and folder at the start of the toolbar, where
/// macOS would draw the window's title and subtitle. Drawn here so the
/// folder name reads: the system's subtitle measured 3.32:1 in light (2x
/// capture of the active window). The quiet label color drew it at 4.46:1
/// offscreen, too near the line, so both lines use the label color and
/// the folder is set apart by its smaller size.
///
/// A saved conversation's title is a button with a caret, as in the Claude
/// app, opening Rename, Pin and Delete for it. A new conversation's is
/// plain text, hidden from VoiceOver, which names the window by the same
/// title and folder already.
struct WindowHeading: View {
    let title: String
    let folder: String
    /// The folder line as VoiceOver hears it ("ClaudeNative, on branch main").
    var spokenFolder: String? = nil
    /// The open conversation, once it's saved and can be renamed or deleted.
    var sessionID: String? = nil
    var actions: SessionActions? = nil
    /// Pinned conversations, by id, one per line, as the sidebar keeps them.
    @AppStorage("pinnedConversations") private var pinnedStore = ""

    /// Leave the rest of the toolbar room for its controls. The title
    /// takes at most half a standard conversation line, growing with the
    /// system font rather than with the session title's length.
    private static var maximumWidth: CGFloat { Theme.readingWidth(scale: 1) / 2 }

    private var isPinned: Bool {
        guard let sessionID else { return false }
        return pinnedStore.split(separator: "\n").contains { $0 == sessionID }
    }

    var body: some View {
        if let sessionID, let actions {
            PopUpChoiceButton(name: title, value: spokenFolder ?? folder, valueInName: false) {
                [MenuSection(items: [
                    MenuChoice(title: "Rename…") { actions.perform(.rename, on: sessionID) },
                    MenuChoice(title: isPinned ? "Unpin" : "Pin") { actions.perform(.togglePin, on: sessionID) },
                    MenuChoice(title: SessionArchive.ids().contains(sessionID) ? "Unarchive" : "Archive") { actions.perform(.toggleArchive, on: sessionID) },
                    MenuChoice(title: "Delete…") { actions.perform(.delete, on: sessionID) },
                ])]
            } label: {
                lines
            }
            .help("\(title)\n\(folder)")
        } else {
            lines.accessibilityHidden(true)
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
            Text(folder)
                .font(.subheadline)
        }
        .foregroundStyle(Color(nsColor: .labelColor))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: Self.maximumWidth, alignment: .leading)
    }
}
