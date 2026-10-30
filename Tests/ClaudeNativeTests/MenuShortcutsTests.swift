import AppKit
import Testing
@testable import ClaudeNative

/// Help > Keyboard Shortcuts reads keys off real menu items, in the words
/// Apple's guides use, so VoiceOver says "Shift-Command-T", not "⇧⌘T".
@MainActor
struct MenuShortcutsTests {
    static func item(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @Test func keysAreSpokenInApplesOrder() {
        #expect(MenuShortcuts.spoken(Self.item("New Session", "n", .command)) == "Command-N")
        #expect(MenuShortcuts.spoken(Self.item("New Window", "n", [.command, .option])) == "Option-Command-N")
        #expect(MenuShortcuts.spoken(Self.item("Reopen", "t", [.command, .shift])) == "Shift-Command-T")
        #expect(MenuShortcuts.spoken(Self.item("Shortcuts", "/", .command)) == "Command-Slash")
        #expect(MenuShortcuts.spoken(Self.item("Close Panel", "\\", .command)) == "Command-Backslash")
        #expect(MenuShortcuts.spoken(Self.item("Latest", String(UnicodeScalar(UInt16(NSEndFunctionKey))!), [.command, .control])) == "Control-Command-End")
    }

    /// AppKit stores Shift-Command-T as an uppercase T with Command alone.
    @Test func anUppercaseLetterMeansShift() {
        #expect(MenuShortcuts.spoken(Self.item("Reopen", "T", .command)) == "Shift-Command-T")
    }

    @Test func itemsWithoutKeysAndEmptyMenusAreLeftOut() {
        let bar = NSMenu()
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(Self.item("New Session", "n", .command))
        file.submenu?.addItem(NSMenuItem(title: "Export", action: nil, keyEquivalent: ""))
        file.submenu?.addItem(.separator())
        let empty = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        empty.submenu = NSMenu(title: "Window")
        bar.addItem(file)
        bar.addItem(empty)
        let menus = MenuShortcuts.menus(in: bar)
        #expect(menus.map(\.title) == ["File"])
        #expect(menus.first?.items.map { "\($0.title), \($0.keys)" } == ["New Session, Command-N"])
    }
}

/// Keys on buttons in the window aren't menu items, so reading the menu
/// bar left them out of Help > Keyboard Shortcuts: Send, Stop, F6, Open
/// File, Back, Save and pasting an image.
@MainActor
struct WindowShortcutsTests {
    @Test func theWindowsKeysFollowTheMenus() {
        let menus = MenuShortcuts.all(menus: [MenuShortcuts.Menu(title: "File", items: [])])
        #expect(menus.map(\.title) == ["File", "In the Window"])
        let keys = Dictionary(uniqueKeysWithValues: menus[1].items.map { ($0.title, $0.keys) })
        #expect(keys["Send Message"] == "Command-Return")
        #expect(keys["Move Focus Between Session and Editor"] == "F6")
        #expect(keys["Open File"] == "Command-O")
        #expect(keys["Save File in the Editor"] == "Command-S")
    }
}
