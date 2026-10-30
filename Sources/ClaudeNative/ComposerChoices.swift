import ClaudeNativeCore
import SwiftUI

/// The permission mode menu at the start of the composer's bottom bar, as
/// the Claude app places it: the current mode's name, opening a menu of
/// the modes with what each does.
struct ModeMenu: View {
    @Binding var selection: String
    var opener: MenuOpener? = nil

    /// The modes as the Claude app names them, with its descriptions.
    static let options: [(value: String, title: String, detail: String)] = [
        ("default", "Manual", "Always ask before making changes"),
        ("acceptEdits", "Accept edits", "Automatically accept all file edits"),
        ("plan", "Plan", "Create a plan before making changes"),
        ("bypassPermissions", "Bypass permissions", "Run every tool without asking"),
    ]

    private var title: String { Self.options.first { $0.value == selection }?.title ?? "Manual" }

    var body: some View {
        PopUpChoiceButton(name: "Mode", value: title, sections: {
            [MenuSection(heading: "Mode", items: Self.options.map { option in
                MenuChoice(title: option.title, isChecked: option.value == selection) { selection = option.value }
            })]
        }, opener: opener) {
            Text(title)
        }
        .help("Mode")
    }
}

/// The model menu at the end of the composer's bottom bar: the model's
/// name with the effort after it, quieter ("Opus High"), as one button
/// whose menu chooses both, as the Claude app does.
struct ModelMenu: View {
    @Binding var model: String
    @Binding var effort: String
    let models: [ModelOption]
    let effortLevels: [String]
    var opener: MenuOpener? = nil
    /// The menu's effort group, which Shift-Command-E opens alone.
    static let effortHeading = "Effort"

    /// The model's own name, "Opus 5.5", as the Claude app's button shows
    /// it; the menu keeps the CLI's names ("Default (recommended)").
    private var modelName: String {
        models.first { $0.value == model }?.shortName(among: models) ?? (model == "default" ? "Default" : model)
    }

    private var effortName: String? {
        Self.effortName(effort, levels: effortLevels, modelsKnown: !models.isEmpty)
    }

    /// The effort after the model's name: nothing while the CLI picks it,
    /// and nothing for a model that has no such effort (Haiku read
    /// "Haiku, Max", an effort it doesn't have). Before the CLI has listed
    /// its models, the choice is shown as made.
    static func effortName(_ effort: String, levels: [String], modelsKnown: Bool) -> String? {
        guard effort != "auto", !modelsKnown || levels.contains(effort) else { return nil }
        return EffortWording.title(effort)
    }

    var body: some View {
        PopUpChoiceButton(name: "Model", value: [modelName, effortName].compactMap { $0 }.joined(separator: " "), sections: {
            let choices = models.isEmpty
                ? [MenuChoice(title: "Default", isChecked: true) { model = "default" }]
                : models.map { option in
                    MenuChoice(title: option.displayName, isChecked: option.value == model) { model = option.value }
                }
            var sections = [MenuSection(heading: "Model", items: choices)]
            if !effortLevels.isEmpty {
                sections.append(MenuSection(heading: Self.effortHeading, items: (["auto"] + effortLevels).map { level in
                    MenuChoice(title: level == "auto" ? "Auto" : EffortWording.title(level), isChecked: level == effort) { effort = level }
                }))
            }
            return sections
        }, opener: opener) {
            // One line: the model's name, then the effort, quieter.
            Text(modelName)
                + Text(effortName.map { " " + $0 } ?? "").foregroundStyle(Color(nsColor: Theme.quietLabel))
        }
        .help(models.first { $0.value == model }?.description ?? "Model")
    }
}


/// The folder menu in the composer's bar, as the Claude app's folder
/// button: the recent folders with a checkmark on this one, then Open
/// Folder…. Choosing another folder starts a new session there.
struct FolderMenu: View {
    let current: URL?
    /// Newest first, as the sidebar lists them.
    let recent: [SessionHistory.ProjectSummary]
    let choose: (URL) -> Void
    let openFolder: () -> Void
    /// As many as the Claude app's Recent list shows.
    static let recentLimit = 8

    private var name: String { current?.lastPathComponent ?? "No folder" }

    static func isCurrent(_ project: SessionHistory.ProjectSummary, _ current: URL?) -> Bool {
        current.map { SessionHistory.canonicalPath($0) == SessionHistory.canonicalPath(project.directory) } ?? false
    }

    var body: some View {
        PopUpChoiceButton(name: "Folder", value: name, sections: {
            var sections: [MenuSection] = []
            let listed = recent.prefix(Self.recentLimit)
            if !listed.isEmpty {
                sections.append(MenuSection(heading: "Recent", items: listed.map { project in
                    let checked = Self.isCurrent(project, current)
                    return MenuChoice(title: project.name, isChecked: checked) {
                        // This folder already: nothing to start.
                        if !checked { choose(project.directory) }
                    }
                }))
            }
            sections.append(MenuSection(items: [MenuChoice(title: "Open Folder…", action: openFolder)]))
            return sections
        }) {
            SwiftUI.Label(name, systemImage: "folder")
                .lineLimit(1)
        }
        .help(current?.path ?? "Folder")
    }
}
