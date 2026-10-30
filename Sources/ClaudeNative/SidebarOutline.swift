import AppKit
import SwiftUI

/// Finds the NSOutlineView behind the sidebar's SwiftUI list, so Go >
/// Next Project can scroll to a section header. SwiftUI's `scrollTo`
/// reaches rows, but not a header that's out of view.
@MainActor
final class SidebarOutline {
    /// The window the list is in, searched once the list has built its
    /// outline view (it hasn't yet when the background first appears).
    weak var window: NSWindow?
    private weak var found: NSOutlineView?
    var outlineView: NSOutlineView? {
        get {
            if found == nil { found = window?.contentView.flatMap(SidebarOutlineFinder.Probe.firstOutline) }
            return found
        }
        set { found = newValue }
    }

    /// The rows of section headers, in order: SwiftUI's list makes each
    /// a group item at the outline's top level.
    var headerRows: [Int] {
        guard let outline = outlineView else { return [] }
        return (0..<outline.numberOfRows).filter { row in
            outline.level(forRow: row) == 0
                && outline.delegate?.outlineView?(outline, isGroupItem: outline.item(atRow: row) as Any) == true
        }
    }

    /// Scrolls the `index`th section header to the top of the list.
    /// Whether there was one to scroll to.
    @discardableResult
    func scrollToHeader(_ index: Int) -> Bool {
        let rows = headerRows
        guard let outline = outlineView, rows.indices.contains(index), let scrollView = outline.enclosingScrollView else { return false }
        let clip = scrollView.contentView
        let rect = outline.rect(ofRow: rows[index])
        // The clip's origin sits above the outline by the top inset (the
        // toolbar's height), so the header lands just below the toolbar.
        let top = rect.minY - scrollView.contentInsets.top
        let lowest = outline.bounds.height - clip.bounds.height
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(top, lowest)))
        scrollView.reflectScrolledClipView(clip)
        return true
    }
}

/// Sits in the list's background and hands the window's outline view (the
/// sidebar's list is the only one) to `outline` once it's in a window.
struct SidebarOutlineFinder: NSViewRepresentable {
    let outline: SidebarOutline

    func makeNSView(context: Context) -> NSView { Probe(outline: outline) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        let outline: SidebarOutline
        init(outline: SidebarOutline) {
            self.outline = outline
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            outline.window = window
        }

        static func firstOutline(in view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            for child in view.subviews { if let found = firstOutline(in: child) { return found } }
            return nil
        }
    }
}

/// Hands `found` the window this view is in, once it's in one.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Probe(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        let found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found(window)
        }
    }
}
