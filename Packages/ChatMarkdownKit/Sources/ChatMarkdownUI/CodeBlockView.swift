#if canImport(UIKit)
import CoreText
import UIKit
import ChatCodeBlocks
import ChatMarkdownCore

/// Scrollable code block backed by the viewport engine.
///
/// Visuals: a single bounds-sized viewport view rides the scroll offset and
/// redraws only visible rows — no full-height backing store ever exists.
///
/// Accessibility: at or above `accessibilityGroupingLineThreshold` lines, the
/// view is a container, not one opaque element. VoiceOver sees a header
/// element (language, line count, streaming state, copy action) followed by
/// chunk elements — dozen-line groups materialized only near the viewport
/// (`CodeAccessibilityChunker`). Three-finger scrolling pages the content and
/// announces the new line range, so a 10,000-line block is navigable without
/// ten thousand swipes or ten thousand elements. Below the threshold (e.g. a
/// one-line block by default), the whole block is a single element instead —
/// there's nothing to page through, so no two-finger scrub is needed to
/// leave a group.
public final class CodeBlockView: UIScrollView {
    public let engine: CodeBlockLayoutEngine
    public let language: String?

    /// VoiceOver escape (two-finger scrub, or the "Leave code block" custom
    /// action): the container moves focus to the element after this block so
    /// three-finger swipes scroll the *conversation* again — without this, a
    /// full-viewport code block captures every scroll gesture and there is
    /// no on-screen way out of a 10,000-line region.
    public var onAccessibilityEscape: (() -> Bool)?

    /// Line count at (and above) which the block is exposed as a header +
    /// chunked-navigation container. Below it, the whole block is a single
    /// accessibility element: e.g. a one-line block has nothing worth paging
    /// through, so there is no group to two-finger-scrub out of.
    public var accessibilityGroupingLineThreshold: Int

    private let viewport: CodeViewportView
    private let textInset = CGPoint(x: 12, y: 8)
    private var isStreaming = false

    private var headerElement: LiveFrameAccessibilityElement?
    private var chunkElements: [Int: CodeChunkElement] = [:]
    /// The chunk VoiceOver focus currently sits on. That element is never
    /// pruned from the tree, no matter how far it scrolls — pruning the
    /// focused element strands VoiceOver and forces touch exploration.
    private var voiceOverFocusedChunkIndex: Int?
    /// Line count at the last accessibility refresh — the throttle bucket.
    private var lastAccessibilityLineCount = 0

    public init(
        engine: CodeBlockLayoutEngine,
        language: String?,
        accessibilityGroupingLineThreshold: Int = 2
    ) {
        self.engine = engine
        self.language = language
        self.accessibilityGroupingLineThreshold = accessibilityGroupingLineThreshold
        self.viewport = CodeViewportView(engine: engine, inset: textInset)
        super.init(frame: .zero)
        addSubview(viewport)
        delegate = self
        showsHorizontalScrollIndicator = true
        alwaysBounceVertical = false
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        clipsToBounds = true
        updateContentSize()
        refreshAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CodeBlockView does not support NSCoder")
    }

    // MARK: - Document changes

    /// Called after the underlying `CodeBlockDocument` received an append.
    ///
    /// Appends beyond the visible viewport are the streaming common case
    /// (a capped-height block shows its top while thousands of lines land
    /// below), so both the repaint and the accessibility rebuild are gated:
    /// unconditional per-flush redraws and AX label broadcasts were measured
    /// as the main-thread load during dump streaming on device.
    public func documentDidAppend(_ delta: CodeLineDelta) {
        engine.apply(delta)
        let newContentSize = paddedContentSize()
        if contentSize != newContentSize {
            contentSize = newContentSize
        }
        realignViewport()
        let touchesVisible = delta.touches(visibleRows)
        if touchesVisible {
            viewport.setNeedsDisplay()
        }
        // Accessibility: refresh when visible content changed, or when the
        // line count grew another coarse bucket (the header speaks the
        // count; per-append updates would broadcast to VoiceOver every
        // flush). setStreaming(false) does the exact final refresh.
        if touchesVisible || engine.lineCount - lastAccessibilityLineCount >= 100 {
            refreshAccessibility()
        }
    }

    /// Called after the underlying document was rebuilt wholesale.
    public func documentDidReset() {
        engine.documentDidReset()
        voiceOverFocusedChunkIndex = nil
        contentDidChange()
    }

    /// Whether the closing fence is still outstanding — announced to
    /// VoiceOver as "still receiving".
    public func setStreaming(_ streaming: Bool) {
        guard isStreaming != streaming else { return }
        isStreaming = streaming
        refreshAccessibility()
    }

    private func contentDidChange() {
        updateContentSize()
        realignViewport()
        viewport.setNeedsDisplay()
        refreshAccessibility()
    }

    private func paddedContentSize() -> CGSize {
        let content = engine.contentSize
        return CGSize(
            width: content.width + textInset.x * 2,
            height: content.height + textInset.y * 2
        )
    }

    // MARK: - Geometry

    public override func layoutSubviews() {
        super.layoutSubviews()
        realignViewport()
    }

    private func updateContentSize() {
        contentSize = paddedContentSize()
    }

    private func realignViewport() {
        let target = CGRect(origin: contentOffset, size: bounds.size)
        if viewport.frame != target {
            viewport.frame = target
            viewport.setNeedsDisplay()
        }
    }

    private var visibleRows: Range<Int> {
        let contentRect = CGRect(
            x: 0,
            y: contentOffset.y - textInset.y,
            width: max(bounds.width, 1),
            height: max(bounds.height, 1)
        )
        return engine.rowRange(intersecting: contentRect, overscan: 4)
    }

    // MARK: - Accessibility container

    private func refreshAccessibility() {
        lastAccessibilityLineCount = engine.lineCount
        guard engine.lineCount >= accessibilityGroupingLineThreshold else {
            refreshUngroupedAccessibility()
            return
        }
        isAccessibilityElement = false

        let header: LiveFrameAccessibilityElement
        if let existing = headerElement {
            header = existing
        } else {
            header = LiveFrameAccessibilityElement(accessibilityContainer: self)
            header.referenceView = self
            header.accessibilityTraits = .staticText
            header.accessibilityCustomActions = makeCodeActions()
            headerElement = header
        }
        let name = language.map { "\($0) code block" } ?? "Code block"
        let lineCount = engine.lineCount
        var label = "\(name), \(lineCount) line\(lineCount == 1 ? "" : "s")"
        if isStreaming { label += ", still receiving" }
        header.accessibilityLabel = label
        header.accessibilityHint =
            "Three-finger swipe to scroll by page. Two-finger scrub to leave the code block."
        // Pinned to the visible top edge (container space pans with the
        // content offset), so touch exploration always finds the header.
        header.localFrame = CGRect(
            origin: contentOffset,
            size: CGSize(width: max(bounds.width, 44), height: min(max(bounds.height, 24), 44))
        )

        var chunks = CodeAccessibilityChunker.chunks(covering: visibleRows, document: engine.document)
        var liveChunkIndices = Set(chunks.map(\.index))

        // The focused chunk stays in the tree even outside the materialized
        // window; VoiceOver keeps its anchor, and the next swipe moves
        // relative to it instead of falling back to the header.
        if let focused = voiceOverFocusedChunkIndex, !liveChunkIndices.contains(focused) {
            if let chunk = CodeAccessibilityChunker.chunk(at: focused, document: engine.document) {
                chunks.append(chunk)
                liveChunkIndices.insert(focused)
                chunks.sort { $0.index < $1.index }
            } else {
                voiceOverFocusedChunkIndex = nil // beyond the document (reset)
            }
        }

        var orderedChunks: [CodeChunkElement] = []
        for chunk in chunks {
            let element: CodeChunkElement
            if let cached = chunkElements[chunk.index] {
                element = cached
            } else {
                element = CodeChunkElement(accessibilityContainer: self)
                element.referenceView = self
                element.accessibilityTraits = .staticText
                element.accessibilityCustomActions = makeCodeActions()
                element.onFocusChange = { [weak self] index, focused in
                    guard let self else { return }
                    if focused {
                        self.voiceOverFocusedChunkIndex = index
                    } else if self.voiceOverFocusedChunkIndex == index {
                        self.voiceOverFocusedChunkIndex = nil
                    }
                }
                chunkElements[chunk.index] = element
            }
            element.chunkIndex = chunk.index
            element.accessibilityLabel = chunk.label
            element.localFrame = CGRect(
                x: 0,
                y: textInset.y + engine.yOrigin(forRow: chunk.rows.lowerBound),
                width: max(contentSize.width, bounds.width),
                height: CGFloat(chunk.rows.count) * engine.lineHeight
            )
            orderedChunks.append(element)
        }
        chunkElements = chunkElements.filter { liveChunkIndices.contains($0.key) }
        // Reassigning accessibilityElements invalidates the AX tree — with
        // VoiceOver attached, doing that per streaming flush forces repeated
        // tree walks (measured as a temporary slowdown when VoiceOver was
        // enabled mid-stream). Element instances are cached and updated in
        // place, so skip the assignment whenever the sequence is unchanged.
        let newElements: [Any] = [header] + orderedChunks
        if !Self.identicalElementSequences(newElements, accessibilityElements) {
            accessibilityElements = newElements
        }
    }

    /// Below `accessibilityGroupingLineThreshold`: expose the whole block as
    /// one plain element instead of a header + chunk container — there's
    /// nothing to page through, so no escape gesture is needed to leave it.
    private func refreshUngroupedAccessibility() {
        headerElement = nil
        chunkElements = [:]
        voiceOverFocusedChunkIndex = nil
        accessibilityElements = nil
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Copy code") { [weak self] _ in
                guard let self else { return false }
                UIPasteboard.general.string = self.engine.document.text
                return true
            },
        ]
        let name = language.map { "\($0) code block" } ?? "Code block"
        let lineCount = engine.lineCount
        var label = "\(name), \(lineCount) line\(lineCount == 1 ? "" : "s"): \(engine.document.text)"
        if isStreaming { label += ", still receiving" }
        accessibilityLabel = label
        accessibilityHint = nil
    }

    private static func identicalElementSequences(_ lhs: [Any], _ rhs: [Any]?) -> Bool {
        guard let rhs, lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { ($0 as AnyObject) === ($1 as AnyObject) }
    }

    /// Shared rotor actions for the header and every chunk, so copy/jump/exit
    /// are reachable without traveling back to the header first.
    private func makeCodeActions() -> [UIAccessibilityCustomAction] {
        [
            UIAccessibilityCustomAction(name: "Copy code") { [weak self] _ in
                guard let self else { return false }
                UIPasteboard.general.string = self.engine.document.text
                return true
            },
            UIAccessibilityCustomAction(name: "Go to start of code block") { [weak self] _ in
                self?.jumpToBoundary(top: true) ?? false
            },
            UIAccessibilityCustomAction(name: "Go to end of code block") { [weak self] _ in
                self?.jumpToBoundary(top: false) ?? false
            },
            UIAccessibilityCustomAction(name: "Leave code block") { [weak self] _ in
                self?.onAccessibilityEscape?() ?? false
            },
        ]
    }

    private func jumpToBoundary(top: Bool) -> Bool {
        let target = CGPoint(x: 0, y: top ? 0 : maxContentOffset.y)
        setContentOffset(target, animated: false)
        realignViewport()
        refreshAccessibility()
        let row = top ? 0 : max(0, engine.lineCount - 1)
        if let element = chunkElements[CodeAccessibilityChunker.chunkIndex(forRow: row)] {
            UIAccessibility.post(notification: .layoutChanged, argument: element)
        }
        return true
    }

    /// VoiceOver two-finger scrub.
    public override func accessibilityPerformEscape() -> Bool {
        onAccessibilityEscape?() ?? false
    }

    /// Three-finger VoiceOver scrolling: page the viewport, then move focus
    /// to the first newly visible chunk so the next swipe reads from where
    /// the scroll landed — no touch exploration to re-find the content.
    ///
    /// Direction semantics follow the finger, matching the rest of iOS:
    /// swipe up reveals content below (offset increases), exactly as swipe
    /// left reveals content to the right. (An earlier version inverted the
    /// vertical pair relative to the horizontal pair, which dead-ended
    /// vertical scrolling at the top of a freshly bound block.)
    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let verticalPage = max(bounds.height * 0.8, engine.lineHeight)
        let horizontalPage = bounds.width * 0.8
        var target = contentOffset
        switch direction {
        case .up:
            target.y = min(maxContentOffset.y, contentOffset.y + verticalPage)
        case .down:
            target.y = max(0, contentOffset.y - verticalPage)
        case .left:
            target.x = min(maxContentOffset.x, contentOffset.x + horizontalPage)
        case .right:
            target.x = max(0, contentOffset.x - horizontalPage)
        default:
            return false
        }
        guard target != contentOffset else { return false }
        setContentOffset(target, animated: false)
        realignViewport()
        refreshAccessibility()

        // Focus the chunk at the top of the (exact, no-overscan) new viewport.
        // Its label carries the position ("Lines X to Y of N: …"), so the
        // focus move is also the page announcement.
        let exactRows = engine.rowRange(
            intersecting: CGRect(
                x: 0,
                y: contentOffset.y - textInset.y,
                width: max(bounds.width, 1),
                height: max(bounds.height, 1)
            ),
            overscan: 0
        )
        if let firstRow = exactRows.first,
           let element = chunkElements[CodeAccessibilityChunker.chunkIndex(forRow: firstRow)] {
            UIAccessibility.post(notification: .layoutChanged, argument: element)
        } else {
            UIAccessibility.post(
                notification: .pageScrolled,
                argument: "Lines \(exactRows.lowerBound + 1) to \(exactRows.upperBound) of \(engine.lineCount)"
            )
        }
        return true
    }

    private var maxContentOffset: CGPoint {
        CGPoint(
            x: max(0, contentSize.width - bounds.width),
            y: max(0, contentSize.height - bounds.height)
        )
    }
}

extension CodeBlockView: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        realignViewport()
        refreshAccessibility()
    }
}

/// A code chunk accessibility element that reports VoiceOver focus changes,
/// so the container can pin the focused chunk in the tree while it scrolls.
final class CodeChunkElement: LiveFrameAccessibilityElement {
    var chunkIndex: Int = -1
    var onFocusChange: ((Int, Bool) -> Void)?

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        onFocusChange?(chunkIndex, true)
    }

    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        onFocusChange?(chunkIndex, false)
    }
}

/// Bounds-sized drawing surface positioned at the scroll offset. Draws only
/// the rows intersecting its frame; row CTLines come from the engine's LRU.
final class CodeViewportView: UIView {
    private let engine: CodeBlockLayoutEngine
    private let inset: CGPoint

    init(engine: CodeBlockLayoutEngine, inset: CGPoint) {
        self.engine = engine
        self.inset = inset
        super.init(frame: .zero)
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CodeViewportView does not support NSCoder")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        RenderSignposts.list.withIntervalSignpost("code.viewportDraw") {
            drawRows(in: context)
        }
    }

    private func drawRows(in context: CGContext) {
        // Content rect this viewport covers (frame rides the content offset).
        let contentRect = frame.offsetBy(dx: -inset.x, dy: -inset.y)
        let rows = engine.rowRange(intersecting: contentRect, overscan: 1)
        guard !rows.isEmpty else { return }

        context.setFillColor(UIColor.label.cgColor)
        for row in rows {
            let layout = engine.layout(row: row)
            let baselineY = inset.y + engine.yOrigin(forRow: row) + engine.ascent - frame.origin.y
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: inset.x - frame.origin.x, y: baselineY)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(layout.line, context)
            context.restoreGState()
        }
    }
}
#endif
