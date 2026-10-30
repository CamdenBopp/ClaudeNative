import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative

/// The Files tree: each row one element, a folder read as "name, folder",
/// and no row a heading (SwiftUI's List made every folder one).
/// One at a time: the focus tests need their own window to be key.
@MainActor
@Suite(.serialized)
struct FileTreeOutlineTests {
    @Test func foldersAreRowsNotHeadings() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filetree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Sources"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(path: "README.md"))
        let (window, host) = AccessibilityHost.window(hosting: FileTreeOutline(root: root) { _ in }, size: NSSize(width: 400, height: 300))
        defer { window.close() }
        for _ in 0..<20 {
            AccessibilityHost.settle(host)
            if (MessageNavigationHostedTests.Hosted.views(NSOutlineView.self, in: host).first?.numberOfRows ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let outline = try #require(MessageNavigationHostedTests.Hosted.views(NSOutlineView.self, in: host).first)
        let cells = (0..<outline.numberOfRows).compactMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: true) }
        let all = cells.flatMap { [$0 as AnyObject] + AccessibilityHost.descendants(of: $0) }
        // What VoiceOver can land on in each row: one element, its name.
        let elements = all.compactMap { $0 as? NSView }.filter { $0.isAccessibilityElement() }.compactMap { $0.accessibilityLabel() }
        #expect(elements == ["Sources, folder", "README.md"])
        #expect(!all.contains { AccessibilityHost.role($0)?.rawValue == "AXHeading" })
    }

    /// Each row offers Show in Finder to VoiceOver (VO-Command-Space) and
    /// in its right-click menu, which acts on the row clicked.
    @Test func everyRowOffersShowInFinder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filetree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Sources"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(path: "README.md"))
        let (window, host) = AccessibilityHost.window(hosting: FileTreeOutline(root: root) { _ in }, size: NSSize(width: 400, height: 300))
        defer { window.close() }
        for _ in 0..<20 {
            AccessibilityHost.settle(host)
            if (MessageNavigationHostedTests.Hosted.views(NSOutlineView.self, in: host).first?.numberOfRows ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let outline = try #require(MessageNavigationHostedTests.Hosted.views(NSOutlineView.self, in: host).first)
        let cells = (0..<outline.numberOfRows).compactMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: true) }
        #expect(cells.count == 2)
        for cell in cells {
            #expect(AccessibilityHost.customActions(cell).map(\.name) == ["Show in Finder"])
        }
        #expect(outline.menu?.items.map(\.title) == ["Show in Finder"])
        // VoiceOver stayed on "Files table" as the selection moved (live),
        // so the table offers it too, for the selected row.
        #expect(AccessibilityHost.customActions(outline).map(\.name) == ["Show in Finder"])
    }

    /// The list's scroll view isn't an element of its own: VoiceOver's
    /// cursor stopped on it, an unnamed "scroll area", while the keyboard
    /// was in the list.
    /// Clearing the filter brings the tree back, and the tree's load used
    /// to take keyboard focus (and VoiceOver) from the field still being
    /// edited. It doesn't take focus from a field you're typing in.
    @Test func clearingTheFilterLeavesFocusInTheField() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filetree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(path: "README.md"))
        let (window, host) = AccessibilityHost.window(hosting: FilesView(folder: root) { _ in }, size: NSSize(width: 400, height: 300))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let field = try #require(MessageNavigationHostedTests.Hosted.views(NSTextField.self, in: host).first { $0.isEditable })
        // The tree's own first load, and the focus it takes then, before
        // any typing: a busy run finished it after the field had focus.
        for _ in 0..<100 where !(window.firstResponder is NSOutlineView) {
            AccessibilityHost.settle(host)
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(window.firstResponder is NSOutlineView)
        window.makeFirstResponder(field)
        func type(_ text: String) {
            field.stringValue = text
            (window.firstResponder as? NSTextView)?.string = text
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            AccessibilityHost.settle(host)
        }
        type("READ")
        try await Task.sleep(for: .milliseconds(300))
        type("")
        try await Task.sleep(for: SidePanelLayout.appearanceDuration + .milliseconds(500))
        AccessibilityHost.settle(host)
        // The defect is the tree taking focus. (In a busy full suite the
        // simulated typing can end the field's edit session, leaving the
        // window itself first responder; live, the field keeps it.)
        #expect(!(window.firstResponder is NSOutlineView), "focus is on \(String(describing: window.firstResponder))")
    }

    /// After Go to File (which starts in the filter), F6 moves into the
    /// tree. It did nothing: the tree had been told not to take focus.
    @Test func f6MovesIntoTheTreeAfterGoToFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filetree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(path: "README.md"))
        let (window, host) = AccessibilityHost.window(hosting: FilesView(folder: root, focusToken: 0, startsInFilter: true) { _ in }, size: NSSize(width: 400, height: 300))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: SidePanelLayout.appearanceDuration + .milliseconds(300))
        // Go to File's keyboard is in the filter.
        let field = try #require(MessageNavigationHostedTests.Hosted.views(NSTextField.self, in: host).first { $0.isEditable })
        window.makeFirstResponder(field)
        AccessibilityHost.settle(host)
        host.rootView = FilesView(folder: root, focusToken: 1, startsInFilter: true) { _ in }
        AccessibilityHost.settle(host)
        #expect(window.firstResponder is NSOutlineView, "focus is on \(String(describing: window.firstResponder))")
    }

    /// While a filter's search hasn't come back, the panel says it's
    /// searching; "No Matches" showed from the first letter typed.
    @Test func aFilterSaysSearchingUntilItsResultsArrive() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filetree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(path: "README.md"))
        let (window, host) = AccessibilityHost.window(hosting: FilesView(folder: root) { _ in }, size: NSSize(width: 400, height: 300))
        defer { window.close() }
        let field = try #require(MessageNavigationHostedTests.Hosted.views(NSTextField.self, in: host).first { $0.isEditable })
        window.makeFirstResponder(field)
        field.stringValue = "readme"
        (window.firstResponder as? NSTextView)?.string = "readme"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        AccessibilityHost.settle(host)
        func shown() -> [String] { AccessibilityHost.descendants(of: host).compactMap { AccessibilityHost.label($0) ?? AccessibilityHost.value($0) } }
        #expect(!shown().contains("No Matches"), "\(shown())")
        #expect(shown().contains { $0.hasPrefix("Searching") }, "\(shown())")
        // Once the search is back, the results replace it.
        for _ in 0..<60 where shown().contains(where: { $0.hasPrefix("Searching") }) {
            AccessibilityHost.settle(host)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!shown().contains { $0.hasPrefix("Searching") })
        #expect(!shown().contains("No Matches"))
    }

    @Test func theScrollAreaIsNotAStop() throws {
        let root = FileManager.default.temporaryDirectory
        let (window, host) = AccessibilityHost.window(hosting: FileTreeOutline(root: root) { _ in }, size: NSSize(width: 400, height: 300))
        defer { window.close() }
        AccessibilityHost.settle(host)
        let outline = try #require(MessageNavigationHostedTests.Hosted.views(NSOutlineView.self, in: host).first)
        let scrollView = try #require(outline.enclosingScrollView)
        #expect(!scrollView.isAccessibilityElement())
    }
}
