import AppKit
import ChatMarkdownAppKit
import ChatMarkdownCore
import ClaudeNativeCore
import SwiftUI

/// How a row is drawn. Your messages sit in a tint on the trailing side;
/// Claude's replies and notices are plain text across the column; tool calls
/// are a compact card with a status symbol.
private enum RowStyle {
    case reply, bubble, tool

    init(_ kind: TranscriptEntry.Kind) {
        switch kind {
        case .user: self = .bubble
        case .tool: self = .tool
        case .assistant, .notice, .thinking: self = .reply
        }
    }
}

/// A rounded fill drawn behind a row's text. Drawing happens under the view's
/// appearance, so the semantic fill colors follow light, dark and Increase
/// Contrast.
private final class RoundedFillView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var radius: CGFloat = 0 { didSet { needsDisplay = true } }
    /// The edge drawn inside the bounds, so cards stay visible where the
    /// fill alone is too close to the window.
    var border: NSColor? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let inset = (border == nil ? 0 : Theme.hairlineWidth / 2)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let border {
            border.setStroke()
            path.lineWidth = Theme.hairlineWidth
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A row's text. It draws and speaks like any wrapping label; a reply's
/// height comes from the row's kept layout instead of the label laying the
/// whole reply out again each time it grows.
private final class BodyLabel: NSTextField {
    /// The reply as laid out, when the row shows one.
    var replyLayout: ReplyTextLayout?

    override var intrinsicContentSize: NSSize {
        let insets = alignmentRectInsets
        let width = bounds.width - insets.left - insets.right
        guard let replyLayout, replyLayout.matchesLabel, preferredMaxLayoutWidth == 0, width > 0 else {
            return super.intrinsicContentSize
        }
        // A wrapping label without a preferred width reports no intrinsic
        // width and the height of its text at its current width.
        return NSSize(width: NSView.noIntrinsicMetric, height: replyLayout.height(width: width))
    }

    /// The height above depends on the width, and AppKit doesn't ask again
    /// when only the width changes: a reply first laid out 44 points wide
    /// kept that 19,000-point height at full width, and its code cards were
    /// placed for it.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, replyLayout != nil { invalidateIntrinsicContentSize() }
    }
}

/// One conversation entry. VoiceOver reads most rows as a single static
/// text whose value is the whole message; a Claude reply is a group named
/// "Claude" holding one element per Markdown block.
final class MessageRowView: NSView {
    private let speaker = NSTextField(labelWithString: "")
    private let body = BodyLabel(wrappingLabelWithString: "")
    /// The tint behind your message, or the card behind a tool call.
    private let backdrop = RoundedFillView()
    /// A tool call's status symbol. The status is also written as a word.
    private let statusIcon = NSImageView()
    /// A visible pointer target; the same operation is offered on the
    /// row's VoiceOver actions, preserving its single stable AX element.
    private let outputDisclosure = NSButton()
    private var outputDisclosureWidth: NSLayoutConstraint?
    private var outputOverride: Bool?
    private var outputIsExpanded: Bool { outputOverride ?? showsToolOutput }
    private var style: RowStyle?
    /// Cards drawn behind the code blocks of a reply, in order.
    private var codeCards: [RoundedFillView] = []
    /// The language caption drawn in each code card's top corner.
    private var codeCaptions: [NSTextField] = []
    /// The reply as rendered, to find where its code blocks are laid out.
    /// Set it with `showCode(_:unchangedLength:)`.
    private var codeSource: NSAttributedString? {
        didSet { placedCodeCards = nil; needsLayout = true }
    }
    /// The cards' measurements, kept for the part of the reply that did not
    /// change, so a streaming delta measures only the cards at its end.
    private var cardLayout = CodeCardLayout()

    /// Shows a newly rendered reply's code cards. `unchangedLength` is how
    /// much of the text is exactly as before.
    private func showCode(_ text: NSAttributedString?, unchangedLength: Int) {
        if text == nil { cardLayout.reset() }
        cardLayout.textChanged(unchangedLength: unchangedLength)
        if let text, let font = body.font {
            let layout = body.replyLayout ?? ReplyTextLayout()
            layout.setText(text, unchangedLength: unchangedLength, font: font)
            body.replyLayout = layout
        } else {
            body.replyLayout = nil
        }
        codeSource = text
    }
    /// Where the code cards are, in the row's coordinates, for tests.
    var codeCardFrames: [NSRect] { codeCards.filter { !$0.isHidden }.map(\.frame) }
    /// The row size the code cards were last placed for.
    private var placedCodeCards: NSSize?
    private var styleConstraints: [RowStyle: [NSLayoutConstraint]] = [:]
    private var shown: TranscriptEntry?
    /// Whether the "Claude", "You" or tool label is drawn.
    var showsLabel: Bool { !speaker.isHidden }
    /// What kind of row this is, for the row added after it.
    var shownKind: TranscriptEntry.Kind? { shown?.kind }
    /// The entry this row shows, for rotors.
    var entry: TranscriptEntry? { shown }
    var openFile: (URL) -> Void = { _ in }
    var showChanges: (TranscriptEntry) -> Void = { _ in }
    var openInNewWindow: (URL) -> Void = { _ in }
    var toggleMark: (String) -> Void = { _ in }
    /// Whether the user marked this row; shown and spoken, and offered to
    /// the Marked Messages rotor.
    var isMarked = false {
        didSet {
            guard isMarked != oldValue else { return }
            redraw()
        }
    }

    /// Draws the row again from the transcript's entry (the shown one may
    /// already have tool output added). A finished reply stays finished:
    /// drawn again as still streaming, it lost its link and code actions
    /// until something else finished it.
    /// Whether output was expanded when the row was last shown.
    private var expandedWhenShown = false

    private func redraw() {
        guard let entry = source ?? shown else { return }
        let wasFinished = markdown.isFinished
        shown = nil
        show(entry, base: lastBase)
        if wasFinished { finishMarkdown() }
    }
    private var lastBase: URL?
    /// The conversation's text scale; changing it redraws the row in place.
    var textScale: Double {
        didSet {
            guard textScale != oldValue else { return }
            applyFonts()
            markdown.bodySize = Theme.conversationTextSize(.body, scale: textScale)
            redraw()
        }
    }

    init(entry: TranscriptEntry, base: URL?, textScale: Double) {
        self.textScale = textScale
        super.init(frame: .zero)
        markdown.bodySize = Theme.conversationTextSize(.body, scale: textScale)
        speaker.textColor = Theme.quietLabel
        speaker.setContentCompressionResistancePriority(.required, for: .horizontal)
        speaker.setContentHuggingPriority(.required, for: .horizontal)
        body.isSelectable = true
        // Without this a selectable label drops its attributes when clicked.
        body.allowsEditingTextAttributes = true
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        backdrop.setAccessibilityElement(false)
        statusIcon.setAccessibilityElement(false)
        addSubview(backdrop)
        outputDisclosure.isBordered = false
        outputDisclosure.refusesFirstResponder = true
        outputDisclosure.imagePosition = .imageOnly
        outputDisclosure.target = self
        outputDisclosure.action = #selector(toggleOutput)
        outputDisclosure.setAccessibilityElement(false)
        outputDisclosure.cell?.setAccessibilityElement(false)
        outputDisclosure.isHidden = true
        addSubview(outputDisclosure)
        for view in [statusIcon, speaker, body] as [NSView] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        // A label's cell posts AXValueChanged whenever its text changes,
        // even with the label hidden from VoiceOver. A running tool's time
        // rewrites the title every second, and a streaming reply rewrites the
        // body every update, so both cells are hidden and stay silent; the
        // row's own value is what VoiceOver reads.
        speaker.cell?.setAccessibilityElement(false)
        body.cell?.setAccessibilityElement(false)
        for view in [backdrop, statusIcon, speaker, body, outputDisclosure] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        makeStyleConstraints()
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        show(entry, base: base)
    }

    /// The constraints for each style; only the row's current style is active.
    private func makeStyleConstraints() {
        let space = Theme.Spacing.self
        let disclosureWidth = outputDisclosure.widthAnchor.constraint(equalToConstant: 0)
        disclosureWidth.isActive = true
        outputDisclosureWidth = disclosureWidth
        let bubbleWidth = backdrop.widthAnchor.constraint(
            lessThanOrEqualTo: widthAnchor, multiplier: Theme.bubbleWidthShare
        )
        styleConstraints[.reply] = [
            speaker.topAnchor.constraint(equalTo: topAnchor),
            speaker.leadingAnchor.constraint(equalTo: leadingAnchor),
            speaker.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        styleConstraints[.bubble] = [
            // The label sits over the tint's text, on the trailing side.
            speaker.topAnchor.constraint(equalTo: topAnchor),
            speaker.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -space.large),
            speaker.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            backdrop.topAnchor.constraint(equalTo: speaker.bottomAnchor, constant: space.xSmall),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            bubbleWidth,
            body.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: space.medium),
            body.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -space.medium),
            body.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: space.large),
            body.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -space.large),
        ]
        styleConstraints[.tool] = [
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusIcon.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: space.medium),
            statusIcon.centerYAnchor.constraint(equalTo: speaker.centerYAnchor),
            speaker.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: space.small),
            speaker.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: space.small),
            speaker.bottomAnchor.constraint(lessThanOrEqualTo: backdrop.bottomAnchor, constant: -space.small),
            body.leadingAnchor.constraint(equalTo: speaker.trailingAnchor, constant: space.small),
            body.firstBaselineAnchor.constraint(equalTo: speaker.firstBaselineAnchor),
            body.trailingAnchor.constraint(equalTo: outputDisclosure.leadingAnchor, constant: -space.xSmall),
            body.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -space.small),
            outputDisclosure.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -space.small),
            outputDisclosure.centerYAnchor.constraint(equalTo: speaker.centerYAnchor),
            outputDisclosure.heightAnchor.constraint(equalToConstant: Theme.iconButtonSize),
        ]
    }

    /// A reply's text sits under its "Claude" label, or at the row's top
    /// when the label is hidden.
    private lazy var replyBodyBelowLabel = body.topAnchor.constraint(equalTo: speaker.bottomAnchor, constant: Theme.Spacing.xSmall)
    private lazy var replyBodyAtTop = body.topAnchor.constraint(equalTo: topAnchor)

    /// Set when an earlier reply in this turn already showed "Claude". As
    /// in the Claude app, the turn shows it once; VoiceOver still names
    /// every reply.
    var continuesTurn = false {
        didSet {
            guard continuesTurn != oldValue else { return }
            redraw()
        }
    }

    private func placeReplyLabel(for entry: TranscriptEntry) {
        guard style == .reply else {
            NSLayoutConstraint.deactivate([replyBodyBelowLabel, replyBodyAtTop])
            speaker.isHidden = false
            return
        }
        // A marked reply keeps its label, which says so.
        let hidden = continuesTurn && entry.kind == .assistant && !isMarked
        speaker.isHidden = hidden
        NSLayoutConstraint.deactivate([hidden ? replyBodyBelowLabel : replyBodyAtTop])
        NSLayoutConstraint.activate([hidden ? replyBodyAtTop : replyBodyBelowLabel])
    }

    private func apply(_ newStyle: RowStyle) {
        guard newStyle != style else { return }
        if let style { NSLayoutConstraint.deactivate(styleConstraints[style] ?? []) }
        style = newStyle
        NSLayoutConstraint.activate(styleConstraints[newStyle] ?? [])
        backdrop.isHidden = newStyle == .reply
        statusIcon.isHidden = newStyle != .tool
        switch newStyle {
        case .bubble:
            backdrop.fill = Theme.bubbleFill
            backdrop.border = Theme.cardBorder
            backdrop.radius = Theme.Radius.bubble
        case .tool:
            backdrop.fill = Theme.cardFill
            backdrop.border = Theme.cardBorder
            backdrop.radius = Theme.Radius.card
        case .reply:
            break
        }
        applyFonts()
        body.textColor = newStyle == .tool ? Theme.quietLabel : .labelColor
        // A reply fills the column; tints and cards hug their text, so they
        // wrap at a width set in layout().
        body.setContentHuggingPriority(newStyle == .reply ? .defaultLow : .defaultHigh, for: .horizontal)
        body.preferredMaxLayoutWidth = 0
        needsLayout = true
    }

    /// Sizes the row's text for its style and the text scale. Author labels
    /// are small and quiet; a tool's status word shares its line with the
    /// summary, so it matches the summary's size.
    private func applyFonts() {
        let bodySize = Theme.conversationTextSize(.body, scale: textScale)
        let labelSize = style == .tool ? bodySize : Theme.conversationTextSize(.subheadline, scale: textScale)
        speaker.font = .systemFont(ofSize: labelSize, weight: .semibold)
        body.font = .systemFont(ofSize: bodySize)
        statusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: bodySize, weight: .regular)
        placedCodeCards = nil
        cardLayout.reset()
        // Text without a font of its own takes the label's, so it is laid
        // out again from the start.
        body.replyLayout?.reset()
        needsLayout = true
    }

    /// The widest a tint's or card's text may run before it wraps, so a
    /// short message gets a small tint and a long one stops at its share of
    /// the column.
    override func layout() {
        super.layout()
        let widest: CGFloat
        switch style {
        case .bubble?:
            widest = bounds.width * Theme.bubbleWidthShare - 2 * Theme.Spacing.large
        case .tool?:
            widest = bounds.width - body.frame.minX - Theme.Spacing.medium - (outputDisclosureWidth?.constant ?? 0)
        case .reply?:
            placeCodeCards()
            return
        case nil:
            return
        }
        let width = max(0, widest.rounded(.down))
        guard abs(body.preferredMaxLayoutWidth - width) >= 1 else { return }
        body.preferredMaxLayoutWidth = width
        super.layout()
    }

    /// Puts a card behind each code block. The label lays the blocks out
    /// with their padding and margins but draws no block background, so the
    /// cards are views behind it, placed from the row's kept layout, which
    /// measures what the label's cell measures (ReplyTextLayout says how),
    /// or from the cell itself when that layout can't match it.
    private func placeCodeCards() {
        let width = body.bounds.width
        // Cards are placed from the row's bottom edge (it isn't flipped), so
        // a height change moves them as much as a width change does.
        guard placedCodeCards != bounds.size else { return }
        placedCodeCards = bounds.size
        // The label's frame overhangs its alignment rect; the cards span the
        // alignment rect, which is the column.
        let insets = body.alignmentRectInsets
        let rows = codeSource.map { placeCodeBlocks(in: $0, width: width) } ?? []
        let cardBlocks = codeSource.map { source in
            Self.codeBlocks(in: source).map { range in
                (source.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                    .textBlocks.first as? CodeCardBlock
            }
        } ?? []
        while codeCaptions.count < rows.count {
            let label = NSTextField(labelWithString: "")
            label.textColor = Theme.quietLabel
            // The code block already says its language to VoiceOver.
            label.setAccessibilityElement(false)
            label.cell?.setAccessibilityElement(false)
            addSubview(label)
            codeCaptions.append(label)
        }
        while codeCards.count < rows.count {
            let card = RoundedFillView()
            card.fill = Theme.cardFill
            card.border = Theme.cardBorder
            card.radius = Theme.Radius.card
            card.setAccessibilityElement(false)
            addSubview(card, positioned: .below, relativeTo: body)
            codeCards.append(card)
        }
        for (index, card) in codeCards.enumerated() {
            card.isHidden = index >= rows.count
            guard index < rows.count else { continue }
            let rect = NSRect(
                x: insets.left, y: rows[index].top,
                width: width - insets.left - insets.right, height: rows[index].bottom - rows[index].top
            )
            card.frame = convert(rect, from: body)
            let caption = codeCaptions[index]
            let block = index < cardBlocks.count ? cardBlocks[index] : nil
            caption.isHidden = block?.caption == nil
            if let block, let text = block.caption {
                caption.stringValue = text
                caption.font = block.captionFont
                caption.sizeToFit()
                // Top-left inside the card's padding; the row isn't flipped.
                // The label draws its text inset from its frame; take that
                // off so the caption's first letter lines up with the code.
                caption.setFrameOrigin(NSPoint(
                    x: card.frame.minX + TranscriptLayout.codePadding - caption.alignmentRectInsets.left,
                    y: card.frame.maxY - TranscriptLayout.codePadding - caption.frame.height
                ))
            }
        }
        for caption in codeCaptions.dropFirst(rows.count) { caption.isHidden = true }
    }

    /// The top and bottom of each code block's card, in the label's flipped
    /// coordinates. The text through the end of a block measures to the
    /// card's bottom plus the block's bottom margin; the block alone
    /// measures its card plus both margins. Cards in the unchanged part of
    /// the reply keep their last measurement.
    private func placeCodeBlocks(in text: NSAttributedString, width: CGFloat) -> [(top: CGFloat, bottom: CGFloat)] {
        let blocks = Self.codeBlocks(in: text)
        guard !blocks.isEmpty, width > 0, let cell = body.cell?.copy() as? NSTextFieldCell,
              let font = body.font else { return [] }
        let margin = TranscriptLayout.codeMargin
        let insets = body.alignmentRectInsets
        let textWidth = width - insets.left - insets.right
        let layout = body.replyLayout.flatMap { $0.matchesLabel ? $0 : nil }
        let cards = cardLayout.place(
            blocks: blocks.map { $0.location ..< NSMaxRange($0) }, width: Double(width)
        ) { range in
            let block = NSRange(location: range.lowerBound, length: range.count)
            // The kept layout lays out only what changed; the cell lays the
            // text out from its start for every card.
            if let rect = layout?.blockRect(of: block, width: textWidth) {
                return (top: Double(rect.minY + margin), bottom: Double(rect.maxY - margin))
            }
            let (through, alone) = Self.cellMeasure(block: block, in: text, cell: cell, font: font, width: width)
            return (top: Double(through - alone + margin), bottom: Double(through - margin))
        }
        return cards.map { (top: CGFloat($0.top), bottom: CGFloat($0.bottom)) }
    }

    /// What the label's own cell measures for a code block at a bounds
    /// `width`: the height of the text from its start through the block,
    /// and of the block alone, margins included.
    ///
    /// String drawing lays out a lone line on a quick path that ignores text
    /// blocks, so a one-line block measured by itself comes back as a bare
    /// line and its card collapses. The block is measured after an empty
    /// line instead, which takes the full path the label draws with, and
    /// that line's height is taken off.
    static func cellMeasure(
        block: NSRange, in text: NSAttributedString, cell: NSTextFieldCell, font: NSFont, width: CGFloat
    ) -> (through: CGFloat, alone: CGFloat) {
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        func height(_ string: NSAttributedString) -> CGFloat {
            cell.attributedStringValue = string
            return cell.cellSize(forBounds: bounds).height
        }
        let through = height(text.attributedSubstring(from: NSRange(location: 0, length: NSMaxRange(block))))
        let plain: [NSAttributedString.Key: Any] = [.font: font]
        let emptyLine = height(NSAttributedString(string: "\nx", attributes: plain)) - height(NSAttributedString(string: "x", attributes: plain))
        let led = NSMutableAttributedString(string: "\n", attributes: plain)
        led.append(text.attributedSubstring(from: block))
        return (through, height(led) - emptyLine)
    }

    /// The characters of each code block in a rendered reply, in order.
    static func codeBlocks(in text: NSAttributedString) -> [NSRange] {
        var blocks: [(block: CodeCardBlock, range: NSRange)] = []
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? CodeCardBlock else { return }
            if let last = blocks.last, last.block === block {
                blocks[blocks.count - 1].range = NSUnionRange(last.range, range)
            } else {
                blocks.append((block, range))
            }
        }
        return blocks.map(\.range)
    }

    /// VoiceOver's cursor outlines what is drawn: the tint and its label, or
    /// the tool card, rather than the whole width of the column.
    /// A row can hold keyboard focus when Go > Previous or Next Message
    /// moves to it, because VoiceOver follows keyboard focus; a layout
    /// change naming the row (from the row or the window) left VoiceOver's
    /// cursor where it was. It stays out of the Tab order.
    /// Only while Go moves here: a click on a message's background would
    /// otherwise take focus from the message field, since a window makes
    /// the clicked view first responder whenever it accepts it.
    override var acceptsFirstResponder: Bool { takingNavigationFocus }
    override var canBecomeKeyView: Bool { false }
    private var takingNavigationFocus = false

    /// Gives this row keyboard focus, so VoiceOver's cursor follows to it.
    func takeNavigationFocus() {
        takingNavigationFocus = true
        defer { takingNavigationFocus = false }
        window?.makeFirstResponder(self)
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }

    /// While Go has put keyboard focus here, the system focus ring follows
    /// what the row draws (the tint or the card, or a reply's text), as
    /// VoiceOver's cursor does, so the move can be seen too.
    override var focusRingMaskBounds: NSRect { focusOutline.bounds }
    override func drawFocusRingMask() { focusOutline.fill() }

    private var focusOutline: NSBezierPath {
        // A reply has no card of its own: the ring stands clear of its
        // text, which otherwise touched it (seen in a capture). The
        // label's frame runs past the row by its text inset.
        guard let style, style != .reply else {
            let text = speaker.frame.union(body.frame).intersection(bounds)
            return NSBezierPath(rect: text.insetBy(dx: -Theme.Spacing.small, dy: -Theme.Spacing.xSmall))
        }
        return NSBezierPath(roundedRect: backdrop.frame, xRadius: backdrop.radius, yRadius: backdrop.radius)
    }

    override func accessibilityFrame() -> NSRect {
        guard let window, let style, style != .reply else { return super.accessibilityFrame() }
        let drawn = style == .bubble ? backdrop.frame.union(speaker.frame) : backdrop.frame
        return window.convertToScreen(convert(drawn, to: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A Claude reply's parts, one element per Markdown block.
    private let replyTree = ReplyAccessibilityTree()

    /// The elements inside a reply, in reading order; empty for other rows.
    var replyElements: [ReplyElement] { shown?.kind == .assistant ? replyTree.children : [] }

    /// A reply is a group of its blocks. Every other row speaks as one
    /// element, and its labels are only drawing.
    override func accessibilityChildren() -> [Any]? { replyElements }

    /// The block element under a point on screen, for VoiceOver's mouse and
    /// trackpad commanders.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        for element in replyElements where element.accessibilityFrame().contains(point) {
            return element.accessibilityHitTest(point)
        }
        return super.accessibilityHitTest(point)
    }

    /// Reports the row and its reply's blocks gone, and cuts the blocks
    /// loose, so an element VoiceOver still holds has nothing to read.
    func tearDownAccessibility() {
        var elements = replyTree.children
        var index = 0
        while index < elements.count {
            elements.append(contentsOf: elements[index].items)
            index += 1
        }
        replyTree.reset()
        for element in elements {
            element.parentElement = nil
            element.row = nil
            NSAccessibility.post(element: element, notification: .uiElementDestroyed)
        }
        NSAccessibility.post(element: self, notification: .uiElementDestroyed)
    }

    /// Brings a reply's block elements up to date with what was just drawn.
    private func updateReplyElements() {
        guard shown?.kind == .assistant, let rendered = codeSource else { return }
        replyTree.update(blocks: markdown.blocks, text: rendered, isFinished: markdown.isFinished, row: self)
    }

    /// Where some of a reply's text is drawn, in screen coordinates, for
    /// the block elements' frames. Asked each time, so it follows scrolling,
    /// resizing and the text size.
    func accessibilityFrame(ofText range: NSRange, shape: ReplyElement.Shape) -> NSRect {
        guard window != nil, let rect = textRect(of: range, shape: shape) else { return .zero }
        return NSAccessibility.screenRect(fromView: body, rect: rect)
    }

    /// Scrolls some of a reply's text into view, for a rotor landing on it.
    func scrollTextToVisible(_ range: NSRange, shape: ReplyElement.Shape) {
        guard let rect = textRect(of: range, shape: shape) else { scrollToVisible(bounds); return }
        scrollToVisible(convert(rect, from: body))
    }

    /// Some of the reply's text in the label's coordinates, measured the way
    /// the code cards are: from the kept layout, or the label's own cell.
    private func textRect(of range: NSRange, shape: ReplyElement.Shape) -> NSRect? {
        let insets = body.alignmentRectInsets
        let width = body.bounds.width - insets.left - insets.right
        guard width > 0, let text = codeSource, NSMaxRange(range) <= text.length, range.length > 0 else { return nil }
        let rect: NSRect?
        if let layout = body.replyLayout, layout.matchesLabel {
            switch shape {
            case .card:
                rect = layout.blockRect(of: range, width: width)?.insetBy(dx: 0, dy: TranscriptLayout.codeMargin)
            case .lines:
                rect = layout.lineRect(of: range, width: width)
            case .glyphs:
                rect = layout.lineRect(of: range, width: width, tight: true)
            }
        } else if let cell = body.cell?.copy() as? NSTextFieldCell, let font = body.font {
            let (through, alone) = Self.cellMeasure(block: range, in: text, cell: cell, font: font, width: body.bounds.width)
            rect = NSRect(x: 0, y: through - alone, width: width, height: alone)
        } else {
            rect = nil
        }
        return rect?.offsetBy(dx: insets.left, dy: 0)
    }

    /// The file a tool row names, if it still exists.
    private var fileURL: URL? {
        guard let path = shown?.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Whether this row is a file change whose diff can be shown.
    private var changesFiles: Bool {
        guard case .tool(let name, _) = shown?.kind else { return false }
        return ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(name)
    }

    /// Actions in VoiceOver's actions menu (VO-Command-Space).
    private func updateActions() {
        var messageActions: [NSAccessibilityCustomAction] = []
        if let entry = shown {
            // What was sent or received, Markdown and all, so code pastes
            // the way it was written.
            messageActions.append(NSAccessibilityCustomAction(name: "Copy message") {
                Clipboard.copy(entry.text)
                Announcer.announce("Copied.")
                return true
            })
            messageActions.append(NSAccessibilityCustomAction(name: isMarked ? "Remove mark" : "Mark message") { [weak self] in
                self?.toggleMark(entry.id)
                return true
            })
        }
        self.messageActions = messageActions
        var actions = messageActions
        // Each link to open and each code block to copy, from the reply as
        // a whole, as well as from its block elements. Built once the reply
        // is final, not on every streamed update.
        if shown?.kind == .assistant, markdown.isFinished, let rendered = codeSource {
            actions += Self.replyActions(in: rendered)
        }
        // All of a tool's output, which the row cuts at 20 lines; offered
        // whether or not Show Tool Output is on.
        if case .tool? = source?.kind, let output = source?.output {
            if !output.isEmpty {
                actions.append(NSAccessibilityCustomAction(name: outputIsExpanded ? "Hide Output" : "Show Output") { [weak self] in
                    self?.toggleOutput()
                    return true
                })
            }
            actions.append(NSAccessibilityCustomAction(name: "Copy Output") {
                Clipboard.copy(output)
                Announcer.announce("Output copied.")
                return true
            })
        }
        if changesFiles, let entry = shown {
            actions.append(NSAccessibilityCustomAction(name: "Show changes") { [weak self] in
                self?.showChanges(entry)
                return true
            })
        }
        if let fileURL {
            actions.append(NSAccessibilityCustomAction(name: "Open \(fileURL.lastPathComponent) in the editor") { [weak self] in
                self?.openFile(fileURL)
                return true
            })
            actions.append(NSAccessibilityCustomAction(name: "Open \(fileURL.lastPathComponent) in a new window") { [weak self] in
                self?.openInNewWindow(fileURL)
                return true
            })
        }
        setAccessibilityCustomActions(actions.isEmpty ? nil : actions)
    }

    /// Copy message and Mark message (or Remove mark), which a reply's
    /// block elements offer too.
    private(set) var messageActions: [NSAccessibilityCustomAction] = []

    /// The most links a reply offers as actions, so a reply full of links
    /// doesn't bury the rest of the actions menu.
    static let maxLinkActions = 10
    /// Link schemes a reply's actions open; anything else (a file:// path, a
    /// custom scheme) is left alone rather than launched from a chat.
    static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    /// A link attribute's destination when it's one a reply may open.
    static func openableURL(_ value: Any?) -> URL? {
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url, let scheme = url.scheme?.lowercased(), openableSchemes.contains(scheme) else { return nil }
        return url
    }

    /// What a link is called: its text, or its host when the text is the
    /// address itself.
    static func linkTitle(url: URL, text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == url.absoluteString ? (url.host ?? url.absoluteString) : text
    }

    /// "Open link: <text>" for each distinct link and "Copy code block" for
    /// each code block in a rendered reply, in reading order.
    static func replyActions(in rendered: NSAttributedString) -> [NSAccessibilityCustomAction] {
        var actions: [NSAccessibilityCustomAction] = []
        var seen: Set<URL> = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, range, stop in
            guard let url = openableURL(value), seen.insert(url).inserted else { return }
            let title = linkTitle(url: url, text: rendered.attributedSubstring(from: range).string)
            actions.append(NSAccessibilityCustomAction(name: "Open link: \(title)") {
                NSWorkspace.shared.open(url)
            })
            if seen.count >= maxLinkActions { stop.pointee = true }
        }
        let blocks = codeBlocks(in: rendered)
        for (index, block) in blocks.enumerated() {
            let code = rendered.attributedSubstring(from: block).string.trimmingCharacters(in: .newlines)
            let name = blocks.count == 1 ? "Copy code block" : "Copy code block \(index + 1) of \(blocks.count)"
            actions.append(NSAccessibilityCustomAction(name: name) {
                Clipboard.copy(code)
                Announcer.announce("Copied.")
                return true
            })
        }
        return actions
    }

    /// The same actions VoiceOver offers, as a right-click menu, so none of
    /// them is reachable only through VoiceOver or a double-click.
    override func menu(for event: NSEvent) -> NSMenu? {
        let actions = accessibilityCustomActions() ?? []
        guard !actions.isEmpty else { return nil }
        let menu = NSMenu()
        for action in actions {
            let item = NSMenuItem(title: action.name, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runMenuAction(_ item: NSMenuItem) {
        guard let action = item.representedObject as? NSAccessibilityCustomAction else { return }
        _ = action.handler?()
    }

    /// Double-click shows a file change's diff, or opens a file it read.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return super.mouseDown(with: event) }
        if changesFiles, let entry = shown {
            showChanges(entry)
        } else if let fileURL {
            openFile(fileURL)
        }
    }

    /// A tool's summary as the row draws it, then its output monospaced in
    /// the label color: columns in a listing stay lined up, and the output
    /// is the part to read, not quiet like the summary.
    static func toolText(summary: String, output: String, scale: Double) -> NSAttributedString {
        let size = Theme.conversationTextSize(.body, scale: scale)
        let text = NSMutableAttributedString(string: summary, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.quietLabel,
        ])
        text.append(NSAttributedString(string: "\n" + output, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: NSColor.labelColor,
        ]))
        return text
    }

    /// Whether a tool row draws its output under its summary.
    var showsToolOutput = false {
        didSet {
            guard showsToolOutput != oldValue, let source else { return }
            outputOverride = nil
            shown = nil
            show(source, base: lastBase)
        }
    }

    @objc private func toggleOutput() {
        guard let source else { return }
        outputOverride = !outputIsExpanded
        shown = nil
        show(source, base: lastBase)
        // Expanding leaves the reader at the same place in the transcript.
        enclosingScrollView?.layoutSubtreeIfNeeded()
    }

    private func updateOutputDisclosure() {
        let available: Bool
        if case .tool? = source?.kind, let output = source?.output {
            available = !output.isEmpty
        } else {
            available = false
        }
        outputDisclosure.isHidden = !available
        outputDisclosureWidth?.constant = available ? Theme.iconButtonSize : 0
        outputDisclosure.image = NSImage(systemSymbolName: outputIsExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        outputDisclosure.contentTintColor = Theme.quietLabel
        outputDisclosure.toolTip = outputIsExpanded ? "Hide Output" : "Show Output"
    }

    /// The entry as the transcript has it, before output is added.
    private var source: TranscriptEntry?

    func show(_ given: TranscriptEntry, base: URL?) {
        // Nothing changed: back before the output is formatted. Each
        // streaming update shows every row, and formatting every tool's
        // output each time was 97% of a 112 ms update with 100 long
        // outputs shown. A redraw clears `shown` to get past this.
        if shown != nil, given == source, base == lastBase, outputIsExpanded == expandedWhenShown { return }
        source = given
        expandedWhenShown = outputIsExpanded
        let entry = outputIsExpanded ? given.withToolOutput() : given
        guard entry != shown else { return }
        shown = entry
        lastBase = base
        updateActions()
        apply(RowStyle(entry.kind))
        updateOutputDisclosure()
        let text = RowWording.text(of: entry, base: base)
        let runningSeconds = RowWording.runningSeconds(of: entry, at: Date())
        showTitle(of: entry, runningSeconds: runningSeconds)
        showStatusSymbol(for: entry)
        // A reply is a group of its blocks; every other row is one text.
        setAccessibilityRole(entry.kind == .assistant ? .group : .staticText)
        if entry.kind == .assistant {
            let rendered = markdown.render(text)
            showCode(rendered, unchangedLength: markdown.unchangedLength)
            body.attributedStringValue = rendered
            updateReplyElements()
            // VoiceOver reads the drawn text, so it hears no Markdown syntax.
            speech = RowSpeech(entry: entry, base: base, isMarked: isMarked, renderedText: rendered.string)
        } else if case .tool = entry.kind, let output = given.shownOutput, outputIsExpanded {
            body.attributedStringValue = Self.toolText(summary: RowWording.text(of: given, base: base), output: output, scale: textScale)
            showCode(nil, unchangedLength: 0)
            speech = RowSpeech(entry: entry, base: base, isMarked: isMarked, runningSeconds: runningSeconds)
        } else {
            body.stringValue = text
            showCode(nil, unchangedLength: 0)
            speech = RowSpeech(entry: entry, base: base, isMarked: isMarked, runningSeconds: runningSeconds)
        }
        // Thinking is Claude's working, not its answer: quiet, like a tool's summary.
        if case .thinking = entry.kind { body.textColor = Theme.quietLabel }
    }

    private func showTitle(of entry: TranscriptEntry, runningSeconds: Int?) {
        let visibleTitle = RowWording.visibleTitle(of: entry, runningSeconds: runningSeconds)
        speaker.stringValue = isMarked ? "\(visibleTitle)  ·  Marked" : visibleTitle
        placeReplyLabel(for: entry)
    }

    /// When this row's tool started, while it runs; nil for every other row.
    var runningSince: Date? {
        guard let shown, case .tool(_, .running) = shown.kind else { return nil }
        return shown.startedAt
    }

    /// Brings a running tool's time up to `now`, touching only the title
    /// and the spoken value, and only when the shown time moved. Nothing is
    /// announced: VoiceOver reads the new time when it next lands here.
    func showElapsed(at now: Date) {
        guard let shown, let speech else { return }
        let runningSeconds = RowWording.runningSeconds(of: shown, at: now)
        guard runningSeconds != speech.runningSeconds else { return }
        showTitle(of: shown, runningSeconds: runningSeconds)
        self.speech?.runningSeconds = runningSeconds
    }

    /// Claude replies are Markdown; they stream in, so parsing is incremental.
    private let markdown = StreamingMarkdown()

    func finishMarkdown() {
        guard let rendered = markdown.finish(), shown != nil else { return }
        showCode(rendered, unchangedLength: markdown.unchangedLength)
        body.attributedStringValue = rendered
        speech?.renderedText = rendered.string
        updateActions()
        updateReplyElements()
    }

    /// The whole row as one line, "Claude: …" for a reply, for rotors to
    /// show in their lists.
    var spokenText: String? { speech?.value }

    /// What the row speaks. Every change to it goes through here, so the
    /// final parse of a marked reply still says "marked".
    private var speech: RowSpeech? {
        didSet {
            guard speech != oldValue else { return }
            let isReply = speech?.entry.kind == .assistant
            if isReply {
                // A reply's group is named by its title; its blocks hold the text.
                if accessibilityLabel() != speech?.title { setAccessibilityLabel(speech?.title) }
                if accessibilityValue() != nil { setAccessibilityValue(nil) }
            } else {
                setAccessibilityValue(speech?.value)
            }
            // Without this, VoiceOver kept saying "Claude: ping" while its
            // cursor sat on a row that had just been marked.
            if speech?.titleChanged(from: oldValue) == true {
                NSAccessibility.post(element: self, notification: isReply ? .titleChanged : .valueChanged)
            }
        }
    }

    /// A still symbol for the tool's status; nothing animates.
    private func showStatusSymbol(for entry: TranscriptEntry) {
        guard case .tool(_, let status) = entry.kind else { return }
        let (name, tint): (String, NSColor) = switch status {
        case .awaitingPermission: ("hand.raised", Theme.quietLabel)
        case .running: ("ellipsis.circle", Theme.quietLabel)
        case .succeeded: ("checkmark.circle", Theme.quietLabel)
        case .failed: ("xmark.octagon", .systemRed)
        // The user's own choice, not an error.
        case .denied: ("hand.raised.slash", Theme.quietLabel)
        }
        statusIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        statusIcon.contentTintColor = tint
    }
}
