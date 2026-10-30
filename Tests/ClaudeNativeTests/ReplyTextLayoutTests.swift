import AppKit
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// ReplyTextLayout stands in for the label's own measurement, so it has to
/// agree with it exactly: a point of drift a line puts a code card a few
/// lines off by the end of a long reply. The reference is what the row
/// measured before, the label's cell laying the text out from scratch.
@MainActor
struct ReplyTextLayoutTests {
    /// A long reply with what a coding answer mixes: headings, wrapped
    /// prose, nested lists, quotes, inline code, wide code lines that wrap
    /// inside their card, blank lines in code, one-line blocks, CJK, emoji
    /// and Arabic.
    static func reply(sections: Int = 9) -> String {
        var out: [String] = []
        for step in 1 ... sections {
            out += [
                "## Step \(step): wire up the cache",
                "",
                "The view asks for a value, and the cache answers from memory when it can. Otherwise it loads from disk, which is **slower** but keeps `state` honest, even when the request arrives twice in the same run loop turn.",
                "",
                "- Read the key from the request",
                "  - Nested: look it up, falling back to the *loader*",
                "- Store the result with its `expiry` 🕒 and move on",
                "",
                "> A quote that runs long enough to wrap onto a second line in a narrow column, with `code` inside.",
                "",
                "```swift",
                "struct Cache<Key: Hashable, Value> {",
                "    private var storage: [Key: (value: Value, expiry: Date)] = [:]",
                "",
                "    mutating func value(for key: Key, now: Date = .now, load: () throws -> Value) rethrows -> Value { if let hit = storage[key], hit.expiry > now { return hit.value } }",
                "        let fresh = try load() // 缓存 キャッシュ مخبأ",
                "}",
                "```",
                "",
                "Run it once to check, then again with `--parallel`:",
                "```sh",
                "swift test --filter CacheTests",
                "```",
                "```text",
                "one code line long enough to wrap inside its card at the narrower widths here, and a few more words",
                "```",
                "1. First",
                "2. Second, with a longer item that wraps around the column at most widths we try here",
                "",
            ]
        }
        return out.joined(separator: "\n")
    }

    /// The reply cut into uneven deltas, as the CLI streams it.
    static func prefixes(of text: String) -> [String] {
        var out: [String] = []
        var index = text.startIndex
        var step = 0
        while index < text.endIndex {
            let size = [7, 23, 41, 3, 88][step % 5]
            index = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[..<index]))
            step += 1
        }
        return out
    }

    /// A label set up like a reply row's body.
    static func label(fontSize: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.font = .systemFont(ofSize: fontSize)
        return label
    }

    /// Streams the reply and, every few deltas, holds the persistent layout
    /// to the label's from-scratch measurement: the whole text's height
    /// (from the cell and from the label's intrinsic size), and for each
    /// code block the height through its end and of the block alone, which
    /// is what the cards were placed from.
    static func compare(fontSize: CGFloat, boundsWidth: CGFloat) -> (checks: Int, mismatches: [String]) {
        let label = Self.label(fontSize: fontSize)
        let markdown = StreamingMarkdown()
        markdown.bodySize = fontSize
        let layout = ReplyTextLayout()
        let insets = label.alignmentRectInsets
        let width = boundsWidth - insets.left - insets.right
        let bounds = NSRect(x: 0, y: 0, width: boundsWidth, height: .greatestFiniteMagnitude)
        var checks = 0
        var mismatches: [String] = []
        let prefixes = Self.prefixes(of: Self.reply())
        for (step, shown) in prefixes.enumerated() {
            let rendered = markdown.render(shown)
            layout.setText(rendered, unchangedLength: markdown.unchangedLength, font: label.font!)
            label.attributedStringValue = rendered
            guard step % 6 == 0 || step == prefixes.count - 1 else { continue }
            if layout.text.string != rendered.string { mismatches.append("step \(step): text differs") }
            let cell = label.cell!.copy() as! NSTextFieldCell
            cell.attributedStringValue = rendered
            let whole = cell.cellSize(forBounds: bounds).height
            let ours = layout.height(width: width)
            label.preferredMaxLayoutWidth = width
            let intrinsic = label.intrinsicContentSize.height
            checks += 1
            if whole != ours || intrinsic != ours {
                mismatches.append("step \(step): height cell \(whole) intrinsic \(intrinsic) layout \(ours)")
            }
            for block in MessageRowView.codeBlocks(in: rendered) {
                let measured = MessageRowView.cellMeasure(block: block, in: rendered, cell: cell, font: label.font!, width: boundsWidth)
                let rect = layout.blockRect(of: block, width: width) ?? .zero
                checks += 1
                if measured.through != rect.maxY || measured.alone != rect.height {
                    mismatches.append("step \(step) block \(block): through \(measured.through)/\(rect.maxY) alone \(measured.alone)/\(rect.height)")
                }
            }
        }
        return (checks, mismatches)
    }

    @Test(arguments: [(13.0, 420.0), (13.0, 704.0), (15.6, 611.0), (17.0, 517.0), (22.0, 900.0), (26.0, 330.0)])
    func agreesWithTheLabelsOwnMeasurement(fontSize: Double, boundsWidth: Double) throws {
        let layout = ReplyTextLayout()
        try #require(layout.matchesLabel, "this macOS has no original-font-metrics switch; rows measure with the cell")
        let result = Self.compare(fontSize: fontSize, boundsWidth: boundsWidth)
        #expect(result.checks > 400)
        #expect(result.mismatches.isEmpty, "\(result.mismatches.count) of \(result.checks): \(result.mismatches.prefix(6))")
    }

    /// The real row, streamed in a window and resized midway: its text is as
    /// tall as the label measures it and each card spans its block as the
    /// cell measures it, to the point.
    @Test func streamingRowMatchesTheLabel() throws {
        AccessibilityHost.enable()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView()
        window.contentView = container
        let prefixes = Self.prefixes(of: Self.reply(sections: 5))
        var entry = TranscriptEntry(id: "reply", kind: .assistant, text: prefixes[0])
        let row = MessageRowView(entry: entry, base: nil, textScale: TextScale.standard.factor)
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        let body = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.maximumNumberOfLines == 0 && $0.isSelectable })
        var checks = 0
        var mismatches: [String] = []
        for (step, shown) in prefixes.enumerated() {
            if step == prefixes.count / 2 { window.setContentSize(NSSize(width: 480, height: 600)) }
            entry.text = shown
            row.show(entry, base: nil)
            container.layoutSubtreeIfNeeded()
            guard step % 5 == 0 || step == prefixes.count - 1 else { continue }
            let rendered = body.attributedStringValue
            let cell = body.cell!.copy() as! NSTextFieldCell
            cell.attributedStringValue = rendered
            let measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: body.bounds.width, height: .greatestFiniteMagnitude)).height
            checks += 1
            if body.frame.height != measured { mismatches.append("step \(step): text \(body.frame.height) label \(measured)") }
            let insets = body.alignmentRectInsets
            let expected = MessageRowView.codeBlocks(in: rendered).map { block in
                let edges = MessageRowView.cellMeasure(block: block, in: rendered, cell: cell, font: body.font!, width: body.bounds.width)
                let top = edges.through - edges.alone + 8
                let rect = NSRect(x: insets.left, y: top, width: body.bounds.width - insets.left - insets.right, height: edges.through - 8 - top)
                return row.convert(rect, from: body)
            }
            checks += 1
            if row.codeCardFrames != expected { mismatches.append("step \(step): cards \(row.codeCardFrames) expected \(expected)") }
        }
        #expect(checks > 60)
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(checks): \(mismatches.prefix(4))")
    }

    /// A reopened conversation shows a finished reply all at once, and the
    /// row is first laid out very narrow before the window gives it its
    /// width. Its height and cards must follow the new width: the height
    /// once stayed at the narrow width's 19,000 points and the cards were
    /// placed for it, off the drawn text.
    @Test func finishedRowFollowsAWidthChange() throws {
        AccessibilityHost.enable()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView()
        window.contentView = container
        let entry = TranscriptEntry(id: "reply", kind: .assistant, text: Self.reply(sections: 3))
        let row = MessageRowView(entry: entry, base: nil, textScale: TextScale.standard.factor)
        row.finishMarkdown()
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 760, height: 600))
        container.layoutSubtreeIfNeeded()
        let body = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.maximumNumberOfLines == 0 && $0.isSelectable })
        let rendered = body.attributedStringValue
        let cell = try #require(body.cell?.copy() as? NSTextFieldCell)
        cell.attributedStringValue = rendered
        let measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: body.bounds.width, height: .greatestFiniteMagnitude)).height
        #expect(body.frame.height == measured)
        let font = try #require(body.font)
        let insets = body.alignmentRectInsets
        let expected = MessageRowView.codeBlocks(in: rendered).map { block in
            let edges = MessageRowView.cellMeasure(block: block, in: rendered, cell: cell, font: font, width: body.bounds.width)
            let top = edges.through - edges.alone + 8
            let rect = NSRect(x: insets.left, y: top, width: body.bounds.width - insets.left - insets.right, height: edges.through - 8 - top)
            return row.convert(rect, from: body)
        }
        #expect(!expected.isEmpty)
        #expect(row.codeCardFrames == expected)
    }
}
