import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
import ClaudeNativeCore

/// The editor's line-number gutter, hosted in the real editor pane. Its
/// numbers are checked against the text view's own answer for where each
/// line is (`firstRect(forCharacterRange:)`), not against the gutter's
/// reading of the layout.
@MainActor
struct LineNumberGutterHostedTests {
    static let lineCount = 120
    /// A line long enough to wrap at the test window's width.
    static let wrappedLine = 3
    static let bigger = 1.5
    /// The diff reader's line-number column at 100 percent, which the
    /// gutter matches.
    static let diffNumberColumn: CGFloat = 36
    /// Points of slack between two ways of measuring the same baseline.
    static let tolerance: CGFloat = 0.5

    struct Hosted {
        let window: NSWindow
        let host: NSView
        let textView: FocusableTextView
        let gutter: LineNumberGutter
        let defaults: UserDefaults
        let file: URL
    }

    static func host(_ text: String) throws -> Hosted {
        let file = FileManager.default.temporaryDirectory.appending(path: "Gutter-\(UUID().uuidString).swift")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let defaults = try TextScaleHostedTests.suite()
        let document = EditorDocument(url: file)
        let (window, host) = AccessibilityHost.window(
            hosting: EditorPane(document: document).defaultAppStorage(defaults),
            size: NSSize(width: 640, height: 480)
        )
        let textView = try #require(TextScaleHostedTests.subviews(of: host, as: FocusableTextView.self).first)
        let gutter = try #require(TextScaleHostedTests.subviews(of: host, as: LineNumberGutter.self).first)
        return Hosted(window: window, host: host, textView: textView, gutter: gutter, defaults: defaults, file: file)
    }

    static func sample() -> String {
        (1...lineCount).map { line in
            line == wrappedLine
                ? "let long = \"" + String(repeating: "wrap me ", count: 40) + "\""
                : "let line\(line) = \(line)"
        }.joined(separator: "\n") + "\n"
    }

    /// Where each logical line starts, counted by line feeds.
    static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]
        for (index, unit) in text.utf16.enumerated() where unit == 0x0A { starts.append(index + 1) }
        return starts
    }

    /// Checks every visible logical line has exactly one number, on the
    /// baseline of the line's first fragment as the text view places it.
    static func expectAligned(_ hosted: Hosted, sourceLocation: SourceLocation = #_sourceLocation) {
        let textView = hosted.textView
        let gutter = hosted.gutter
        let font = gutter.font
        let visible = gutter.convert(textView.visibleRect, from: textView)
        // firstRect clips a line to the visible text, so a line cut by the
        // top or bottom edge has no true top to measure from; it still
        // counts as in view.
        var expected: [(number: Int, top: CGFloat, whole: Bool)] = []
        for (index, start) in lineStarts(textView.string).enumerated() {
            let onScreen = textView.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
            let inWindow = hosted.window.convertFromScreen(onScreen)
            let rect = gutter.convert(inWindow, from: nil)
            // The zero-width caret rect, widened so it can intersect.
            let lineRect = NSRect(x: visible.minX, y: rect.minY, width: 1, height: rect.height)
            guard rect.height > 0, lineRect.intersects(visible) else { continue }
            let whole = rect.minY > visible.minY && rect.maxY < visible.maxY
            expected.append((index + 1, gutter.isFlipped ? rect.minY : rect.maxY, whole))
        }
        let marks = gutter.marks()
        #expect(!marks.isEmpty, sourceLocation: sourceLocation)
        #expect(marks.map(\.number) == expected.map(\.number), sourceLocation: sourceLocation)
        #expect(expected.filter(\.whole).count > expected.count / 2, sourceLocation: sourceLocation)
        for (mark, line) in zip(marks, expected) where line.whole {
            // The line's top to its baseline is the font's ascent.
            let ascent = abs(mark.baseline - line.top)
            #expect(
                abs(ascent - font.ascender) <= tolerance,
                "line \(mark.number): baseline \(ascent) below the line's top, font ascent \(font.ascender)",
                sourceLocation: sourceLocation
            )
        }
    }

    @Test func numbersEachVisibleLineOnItsBaselineAndScalesWithTheText() throws {
        let hosted = try Self.host(Self.sample())
        defer { hosted.window.close(); try? FileManager.default.removeItem(at: hosted.file) }
        let textView = hosted.textView
        let gutter = hosted.gutter
        // The editor stays on TextKit 2; touching the old layout manager
        // would have swapped it out.
        #expect(textView.textLayoutManager != nil)

        let standard = Theme.conversationTextSize(.body, scale: TextScale.standard.factor)
        #expect(gutter.font.pointSize == standard)
        #expect(gutter.frame.width == Theme.Spacing.large + Self.diffNumberColumn)
        // The text starts after the gutter.
        let textEdge = textView.convert(NSPoint(x: textView.textContainerOrigin.x, y: 0), to: gutter.superview).x
        #expect(textEdge == gutter.frame.width + Theme.Spacing.small - (textView.textContainer?.lineFragmentPadding ?? 0))

        // The wrapped line really wraps, and is numbered once.
        let wrapped = Self.lineStarts(textView.string)[Self.wrappedLine - 1]
        let wrappedEnd = Self.lineStarts(textView.string)[Self.wrappedLine] - 1
        let firstFragment = textView.firstRect(forCharacterRange: NSRange(location: wrapped, length: 1), actualRange: nil)
        let lastFragment = textView.firstRect(forCharacterRange: NSRange(location: wrappedEnd - 1, length: 1), actualRange: nil)
        #expect(lastFragment.minY < firstFragment.minY, "line \(Self.wrappedLine) should wrap")
        #expect(gutter.marks().filter { $0.number == Self.wrappedLine }.count == 1)
        // The file is taller than the window: only the lines in view.
        #expect(gutter.marks().count < Self.lineCount)
        #expect(gutter.marks().first { $0.isCurrent }?.number == 1)
        Self.expectAligned(hosted)

        // Scrolled to the middle, a mark's position follows the text.
        let clip = try #require(textView.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: textView.frame.height / 2))
        textView.enclosingScrollView?.reflectScrolledClipView(clip)
        AccessibilityHost.settle(hosted.host)
        #expect((gutter.marks().first?.number ?? 0) > Self.wrappedLine)
        Self.expectAligned(hosted)

        // The caret's line is the current one.
        let caretLine = try #require(gutter.marks().dropFirst(2).first?.number)
        textView.setSelectedRange(NSRange(location: Self.lineStarts(textView.string)[caretLine - 1], length: 0))
        #expect(gutter.marks().filter(\.isCurrent).map(\.number) == [caretLine])

        // View > Bigger Text: numbers at the code's size, the column wider.
        hosted.defaults.set(Self.bigger, forKey: TextScale.defaultsKey)
        AccessibilityHost.settle(hosted.host)
        #expect(gutter.font.pointSize == Theme.conversationTextSize(.body, scale: Self.bigger))
        #expect(gutter.frame.width == Theme.Spacing.large + Self.diffNumberColumn * CGFloat(Self.bigger))
        Self.expectAligned(hosted)

        // And back to Actual Size.
        hosted.defaults.set(TextScale.standard.factor, forKey: TextScale.defaultsKey)
        AccessibilityHost.settle(hosted.host)
        #expect(gutter.frame.width == Theme.Spacing.large + Self.diffNumberColumn)
        Self.expectAligned(hosted)
    }

    @Test func widensForMoreDigitsAndTracksEdits() throws {
        // Five digits don't fit the diff reader's four-digit column.
        let manyLines = 12_000
        let text = (1...manyLines).map { "x\($0)" }.joined(separator: "\n")
        let hosted = try Self.host(text)
        defer { hosted.window.close(); try? FileManager.default.removeItem(at: hosted.file) }
        let gutter = hosted.gutter
        let digits = ("88888" as NSString).size(withAttributes: [.font: gutter.font]).width
        #expect(gutter.frame.width == Theme.Spacing.large + ceil(digits))
        #expect(gutter.frame.width > Theme.Spacing.large + Self.diffNumberColumn)

        // Cutting it to a few lines narrows it again.
        let textView = hosted.textView
        #expect(hosted.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 2, length: (textView.string as NSString).length - 2))
        textView.insertText("", replacementRange: textView.selectedRange())
        AccessibilityHost.settle(hosted.host)
        #expect(gutter.frame.width == Theme.Spacing.large + Self.diffNumberColumn)
        #expect(gutter.marks().map(\.number) == [1])
        Self.expectAligned(hosted)
    }

    /// At every View > Bigger Text step the gutter is whole points wide and
    /// the text starts right at its edge, so no pixel column is half gutter,
    /// half text (at 130 percent that showed as a light seam).
    @Test func gutterEdgeIsPixelAlignedAtEveryTextSize() throws {
        let hosted = try Self.host(Self.sample())
        defer { hosted.window.close(); try? FileManager.default.removeItem(at: hosted.file) }
        let scrollView = try #require(hosted.textView.enclosingScrollView)
        for step in TextScale.steps {
            hosted.defaults.set(step, forKey: TextScale.defaultsKey)
            AccessibilityHost.settle(hosted.host)
            let width = hosted.gutter.frame.width
            #expect(width == width.rounded(), "at \(step): \(width)")
            #expect(width >= Self.diffNumberColumn * CGFloat(step) + Theme.Spacing.large, "at \(step)")
            #expect(scrollView.frame.minX == hosted.gutter.frame.maxX, "at \(step)")
            Self.expectAligned(hosted)
        }
    }

    /// The gutter paints only itself. A view doesn't clip to its bounds by
    /// default, and filling the whole dirty rect painted over the editor's
    /// header.
    @Test func gutterPaintsOnlyItsOwnBounds() throws {
        let hosted = try Self.host(Self.sample())
        defer { hosted.window.close(); try? FileManager.default.removeItem(at: hosted.file) }
        let gutter = hosted.gutter
        let size = NSSize(width: gutter.bounds.width * 2, height: gutter.bounds.height)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // A dirty rect twice the gutter's width, as a redraw of the panel can ask for.
        gutter.draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let inside = try #require(bitmap.colorAt(x: 1, y: 1))
        let outside = try #require(bitmap.colorAt(x: Int(size.width) - 2, y: 1))
        #expect(inside.alphaComponent > 0, "the gutter fills its own bounds")
        #expect(outside.alphaComponent == 0, "the gutter painted outside its bounds")
    }

    @Test func gutterIsHiddenFromVoiceOver() throws {
        let hosted = try Self.host(Self.sample())
        defer { hosted.window.close(); try? FileManager.default.removeItem(at: hosted.file) }
        let elements = AccessibilityHost.descendants(of: hosted.window)
        #expect(!elements.contains { $0 === hosted.gutter })
        #expect(!elements.contains { AccessibilityHost.role($0) == .ruler })
        // The text is still the one element VoiceOver lands on for the file.
        let textAreas = elements.filter { AccessibilityHost.role($0) == .textArea }
        #expect(textAreas.count == 1)
        #expect(textAreas.first === hosted.textView)
    }
}
