import AppKit
import SwiftUI

/// What the File and View menus' window keys do in the focused window.
struct WindowMenuActions {
    let newSession: () -> Void
    let toggleSidebar: () -> Void
    let isSidebarShown: Bool
}

extension FocusedValues {
    @Entry var windowMenu: WindowMenuActions?
}

/// The Claude app's window keys: Command-N starts a session, Command-B
/// shows or hides the sidebar, and Command-/ lists every key.
struct WindowCommands: Commands {
    @FocusedValue(\.windowMenu) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Command-N, as in the Claude app. A new window moves to
        // Option-Command-N. With no chat window in front, such as after the
        // last one closed, the new session gets a window of its own.
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                if let actions { actions.newSession() } else { openWindow(id: NewWindowSession.windowID) }
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("New Window") { openWindow(id: NewWindowSession.windowID) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        // Command-B, as in the Claude app.
        CommandGroup(before: .sidebar) {
            Button(actions?.isSidebarShown == false ? "Show Sidebar" : "Hide Sidebar") { actions?.toggleSidebar() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(actions == nil)
        }
        // Command-/, as in the Claude app.
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: KeyboardShortcutsView.windowID) }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}

/// Every menu item that has a key, read from the menu bar itself so the
/// list can't drift from what the keys do.
enum MenuShortcuts {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let keys: String
    }

    struct Menu: Identifiable, Equatable {
        var id: String { title }
        let title: String
        let items: [Item]
    }

    @MainActor
    static func current() -> [Menu] {
        guard let bar = NSApp.mainMenu else { return [] }
        return menus(in: bar)
    }

    /// Keys that belong to a button in the window, not a menu item, so the
    /// menu bar can't list them. Kept by hand: each names the button whose
    /// `.keyboardShortcut` it describes.
    static let inWindow = Menu(title: "In the Window", items: [
        // Composer's send button.
        Item(id: "window send", title: "Send Message", keys: "Command-Return"),
        // Composer's Stop button and the message field's Escape.
        Item(id: "window stop", title: "Stop Claude's Reply", keys: "Command-Period or Escape"),
        // ContentView's hidden F6 button.
        Item(id: "window f6", title: "Move Focus Between Session and Editor", keys: "F6"),
        // The Open File toolbar button.
        Item(id: "window open", title: "Open File", keys: "Command-O"),
        // The side panel's Back button.
        Item(id: "window back", title: "Back in the Side Panel", keys: "Command-Left Bracket"),
        // The editor's Save button.
        Item(id: "window save", title: "Save File in the Editor", keys: "Command-S"),
        // PastesImages, in the message field.
        Item(id: "window paste", title: "Attach a Copied Image", keys: "Command-V"),
        // The Terminal panel's command field.
        Item(id: "terminal interrupt", title: "Interrupt in the Terminal", keys: "Control-C"),
        Item(id: "terminal end input", title: "End Input in the Terminal", keys: "Control-D"),
        Item(id: "terminal suspend", title: "Suspend in the Terminal", keys: "Control-Z"),
    ])

    /// What Help > Keyboard Shortcuts lists: the menu bar's keys, then the
    /// window's.
    static func all(menus: [Menu]) -> [Menu] { menus + [inWindow] }

    static func menus(in bar: NSMenu) -> [Menu] {
        bar.items.compactMap { top in
            guard let submenu = top.submenu else { return nil }
            let items = shortcuts(in: submenu, path: top.title)
            return items.isEmpty ? nil : Menu(title: top.title, items: items)
        }
    }

    private static func shortcuts(in menu: NSMenu, path: String) -> [Item] {
        menu.items.flatMap { item -> [Item] in
            if let submenu = item.submenu {
                return shortcuts(in: submenu, path: "\(path) > \(item.title)")
            }
            guard !item.isHidden, !item.isSeparatorItem, let keys = spoken(item) else { return [] }
            return [Item(id: "\(path) > \(item.title) \(keys)", title: item.title, keys: keys)]
        }
    }

    /// "Shift-Command-T", the way Apple's guides write a key.
    static func spoken(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var flags = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        // An uppercase letter is the letter with Shift.
        if key.count == 1, key.lowercased() != key {
            flags.insert(.shift)
            key = key.lowercased()
        }
        var parts: [String] = []
        if flags.contains(.function) { parts.append("Fn") }
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        parts.append(keyName(key))
        return parts.joined(separator: "-")
    }

    static func keyName(_ key: String) -> String {
        let names: [String: String] = [
            "\r": "Return", "\u{1b}": "Escape", "\t": "Tab", " ": "Space", "\u{8}": "Delete", "\u{7f}": "Delete",
            "/": "Slash", "\\": "Backslash", ";": "Semicolon", "'": "Quote", ",": "Comma", ".": "Period",
            "=": "Equals", "+": "Plus", "-": "Minus", "[": "Left Bracket", "]": "Right Bracket", "`": "Grave Accent",
        ]
        if let name = names[key] { return name }
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 {
            switch Int(scalar.value) {
            case NSUpArrowFunctionKey: return "Up Arrow"
            case NSDownArrowFunctionKey: return "Down Arrow"
            case NSLeftArrowFunctionKey: return "Left Arrow"
            case NSRightArrowFunctionKey: return "Right Arrow"
            case NSHomeFunctionKey: return "Home"
            case NSEndFunctionKey: return "End"
            case NSPageUpFunctionKey: return "Page Up"
            case NSPageDownFunctionKey: return "Page Down"
            case NSF1FunctionKey...NSF35FunctionKey: return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
            default: break
            }
        }
        return key.uppercased()
    }
}

/// Help > Keyboard Shortcuts: every key in the menu bar, one menu per
/// heading (VO-Command-H moves between them), each row read as "New
/// Session, Command-N".
struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"
    @State private var menus: [MenuShortcuts.Menu] = []

    var body: some View {
        List {
            ForEach(menus) { menu in
                Section {
                    ForEach(menu.items) { item in
                        LabeledContent(item.title, value: item.keys)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(item.title), \(item.keys)")
                            // Read as text; without it VoiceOver had no role
                            // to say.
                            .accessibilityAddTraits(.isStaticText)
                    }
                } header: {
                    Text(menu.title)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .frame(minWidth: KeyboardShortcutsLayout.minWidth, minHeight: KeyboardShortcutsLayout.minHeight)
        // Read when the window opens: a session's menu items come and go
        // with the window in front.
        .onAppear { menus = MenuShortcuts.all(menus: MenuShortcuts.current()) }
    }
}

private enum KeyboardShortcutsLayout {
    static let minWidth: CGFloat = 420
    static let minHeight: CGFloat = 480
}
