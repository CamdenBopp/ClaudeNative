import AppKit
import ClaudeNativeCore
import SwiftUI

/// The Files tree as AppKit's own outline view. SwiftUI's List gave every
/// folder row the heading role, so folders were VO-Command-H stops; here
/// they're ordinary rows, as in Finder. Folders load one level at a time.
/// Return or a double-click opens a file; Right and Left Arrow open and
/// close folders, as in any outline.
struct FileTreeOutline: NSViewRepresentable {
    let root: URL
    /// Bumped to move keyboard focus into the tree.
    var focusToken = 0
    /// Whether the tree takes the keyboard once it has loaded; false when
    /// the filter field above has it (Go to File, or typing there). F6
    /// (`focusToken`) moves focus in either way.
    var takesFocus = true
    let openFile: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FileOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .inset
        outline.rowSizeStyle = .default
        outline.autoresizesOutlineColumn = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.openClicked(_:))
        outline.setAccessibilityLabel("Files")
        outline.onReturn = { [weak coordinator = context.coordinator] in coordinator?.openSelected() }
        let menu = NSMenu()
        let show = NSMenuItem(title: Self.showInFinderTitle, action: #selector(Coordinator.showClickedInFinder(_:)), keyEquivalent: "")
        show.target = context.coordinator
        menu.addItem(show)
        outline.menu = menu
        // VoiceOver's cursor stays on the table as the selection moves
        // (live: "Files table" after Down Arrow), so VO-Command-Space
        // there acts on the selected row.
        outline.tableActions = [
            NSAccessibilityCustomAction(name: Self.showInFinderTitle) { [weak coordinator = context.coordinator] in
                coordinator?.showInFinder(row: nil) ?? false
            },
        ]
        context.coordinator.outline = outline
        context.coordinator.openFile = openFile
        context.coordinator.takesFocus = takesFocus
        // Only a later bump of the token is a request for focus.
        context.coordinator.focusToken = focusToken
        context.coordinator.load(root)

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // Not an element of its own: VoiceOver's cursor stopped on it as
        // an unnamed "scroll area" while the keyboard was in the list.
        scrollView.setAccessibilityElement(false)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.openFile = openFile
        if context.coordinator.root != root { context.coordinator.load(root) }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            // Asked for (F6): after Go to File it did nothing, as the tree
            // had been told not to take focus when it loaded.
            context.coordinator.focus()
        }
    }

    static let showInFinderTitle = "Show in Finder"

    /// Opens a Finder window with the entry selected.
    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Takes Return to open the selected file.
    final class FileOutlineView: NSOutlineView {
        var onReturn: () -> Void = {}
        /// Answered here: set with setAccessibilityCustomActions, the
        /// table's actions never reached VoiceOver (live: its menu listed
        /// only "show menu").
        var tableActions: [NSAccessibilityCustomAction] = []
        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { tableActions }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76 { onReturn() } else { super.keyDown(with: event) }
        }
    }

    /// One entry, with its folder's entries read when first expanded.
    final class Node: NSObject {
        let entry: ProjectFiles.Entry
        lazy var children: [Node] = ProjectFiles.children(of: entry.url).map(Node.init)
        init(_ entry: ProjectFiles.Entry) { self.entry = entry }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outline: NSOutlineView?
        var openFile: (URL) -> Void = { _ in }
        var root: URL?
        var focusToken = -1
        var takesFocus = true
        private var roots: [Node] = []

        func load(_ root: URL) {
            self.root = root
            Task { [weak self] in
                let entries = await Task.detached { ProjectFiles.children(of: root) }.value
                guard let self, self.root == root else { return }
                self.roots = entries.map(Node.init)
                self.outline?.reloadData()
                if !self.roots.isEmpty { self.outline?.selectRowIndexes([0], byExtendingSelection: false) }
                // After the panel has slid in, as the side chat waits:
                // taken sooner, the keyboard moved but VoiceOver's cursor
                // stayed on the message field (live).
                try? await Task.sleep(for: SidePanelLayout.appearanceDuration)
                if self.takesFocus { self.focus() }
            }
        }

        func focus() {
            guard let outline else { return }
            outline.window?.makeFirstResponder(outline)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return roots.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return roots[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Node)?.entry.isFolder ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            let cell = NSTableCellView()
            let image = NSImageView(image: NSImage(systemSymbolName: node.entry.isFolder ? "folder" : "doc", accessibilityDescription: nil) ?? NSImage())
            let text = NSTextField(labelWithString: node.entry.name)
            text.lineBreakMode = .byTruncatingMiddle
            text.textColor = .labelColor
            for view in [image, text] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: Theme.Spacing.xSmall),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            // One element: the name, and "folder" for a folder; the outline
            // adds whether it's open. As separate elements VoiceOver read
            // the name twice and the folder icon as "move".
            image.setAccessibilityElement(false)
            text.setAccessibilityElement(false)
            cell.setAccessibilityElement(true)
            cell.setAccessibilityRole(.staticText)
            cell.setAccessibilityLabel(node.entry.isFolder ? "\(node.entry.name), folder" : node.entry.name)
            let url = node.entry.url
            cell.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: FileTreeOutline.showInFinderTitle) {
                    FileTreeOutline.showInFinder(url)
                    return true
                },
            ])
            return cell
        }

        @objc func openClicked(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0 else { return }
            open(outline.item(atRow: outline.clickedRow))
        }

        /// The right-click menu's item: the row clicked, or the selected
        /// row when the menu came from the keyboard.
        @objc func showClickedInFinder(_ sender: Any?) {
            guard let outline else { return }
            showInFinder(row: outline.clickedRow >= 0 ? outline.clickedRow : nil)
        }

        /// Shows `row`'s entry, or the selected row's when it's nil.
        @discardableResult
        func showInFinder(row: Int?) -> Bool {
            guard let outline else { return false }
            let row = row ?? outline.selectedRow
            guard row >= 0, let node = outline.item(atRow: row) as? Node else { return false }
            FileTreeOutline.showInFinder(node.entry.url)
            return true
        }

        func openSelected() {
            guard let outline, outline.selectedRow >= 0 else { return }
            open(outline.item(atRow: outline.selectedRow))
        }

        private func open(_ item: Any?) {
            guard let node = item as? Node else { return }
            if node.entry.isFolder {
                guard let outline else { return }
                if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            } else {
                openFile(node.entry.url)
            }
        }
    }
}
