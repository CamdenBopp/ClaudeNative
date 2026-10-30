import SwiftUI

/// The focused window's side panel, for the View menu.
struct PanelMenuActions {
    let panel: SidePanel
    let showChanges: () -> Void
}

extension FocusedValues {
    @Entry var panelMenu: PanelMenuActions?
}

/// The side panel's items in the View menu, with the Claude app's keys,
/// where VoiceOver's menu bar (VO-M) and Help's search can find them.
/// How the sidebar sections sessions: by their folder, or by date as the
/// Claude app's Group by offers.
/// View > Show Tool Output: what each tool returned, under its row, as the
/// Claude app's Verbose transcript view shows it.
enum ToolOutputSetting {
    static let defaultsKey = "showToolOutput"
}

enum SidebarGrouping: String {
    case folder, date
    static let defaultsKey = "groupSessionsBy"
}

struct PanelCommands: Commands {
    @FocusedValue(\.panelMenu) private var actions
    @AppStorage(SidebarGrouping.defaultsKey) private var grouping = SidebarGrouping.folder
    @AppStorage(ToolOutputSetting.defaultsKey) private var showsToolOutput = false

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Picker("Group Sessions By", selection: $grouping) {
                Text("Folder").tag(SidebarGrouping.folder)
                Text("Date").tag(SidebarGrouping.date)
            }
            // Control-O, the Claude app's key for its Verbose view.
            Toggle("Show Tool Output", isOn: $showsToolOutput)
                .keyboardShortcut("o", modifiers: .control)
            Divider()
            Button("Show Files") { actions?.panel.open(.files) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Go to File…") { actions?.panel.goToFile() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(actions == nil)
            Button("Show Uncommitted Changes") { actions?.showChanges() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Show Terminal") { actions?.panel.open(.terminal) }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(actions == nil)
            Button("Show Side Chat") { actions?.panel.open(.sideChat) }
                .keyboardShortcut(";", modifiers: .command)
                .disabled(actions == nil)
            Button("Close Panel") { actions?.panel.close() }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(actions?.panel.isShown != true)
            // Shift-Command-Backslash, as in the Claude app.
            Button(actions?.panel.isExpanded == true ? "Collapse Panel" : "Expand Panel") { actions?.panel.toggleExpanded() }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(actions?.panel.isShown != true)
        }
    }
}
