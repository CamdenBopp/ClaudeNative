#if canImport(UIKit)
import UIKit
import ChatMarkdownCore
import ChatTextLayout
import ChatCodeBlocks

/// The per-message view: hosts one subview per top-level block (draw-only
/// `TextBlockView`s for prose, virtualized `CodeBlockView`s for code),
/// applies document deltas and layout commits, stacks blocks vertically, and
/// projects the accessibility tree.
///
/// Threading: main-thread only (it is a UIView). All inputs are immutable
/// snapshots produced elsewhere; applying them is bookkeeping plus
/// `setNeedsDisplay`.
///
/// Staleness: `commit(_:)` gates on block existence, revision equality, and
/// the current width bucket — a late commit from an old revision, an old
/// width, or a previous cell tenancy is dropped, never drawn.
public final class MessageBlockContainerView: UIView {
    /// Stacking constants — must match what the height calculator used
    /// (`BlockLayoutScheduler.measuredContentHeight`), which is guaranteed
    /// when both come from the same `MessageLayoutMetrics` value.
    public var metrics = MessageLayoutMetrics() {
        didSet { restack() }
    }

    /// Fired when stacked content height changes — the hosting cell/list
    /// invalidates its layout in response. Only *authoritative* heights are
    /// reported: every non-code block must have a committed layout at the
    /// current width, so estimate-based intermediate stacks never overwrite
    /// an exact measured height in the list geometry.
    public var onContentHeightChange: ((CGFloat) -> Void)?
    /// Fired whenever the natural content *width* changes (max drawn width of
    /// any block, capped at the layout width). Unlike height this is reported
    /// eagerly, including mid-stream: the hosting cell hugs its bubble to this
    /// width, a purely horizontal, geometry-neutral concern.
    public var onContentWidthChange: ((CGFloat) -> Void)?
    /// Link activation (tap or VoiceOver activate). The destination is the
    /// RAW string from the Markdown source — validate before opening.
    /// Return true if handled.
    public var onLinkActivate: ((String) -> Bool)?

    /// Text/link tint applied to prose blocks (`nil` ⇒ system `UIColor.label`).
    /// Set by the hosting cell from the bubble style so tinted bubbles get
    /// legible text.
    public var foregroundColor: UIColor? {
        didSet {
            guard foregroundColor != oldValue else { return }
            for view in textViews.values { view.textColorOverride = foregroundColor }
        }
    }

    public private(set) var contentHeight: CGFloat = 0
    public private(set) var contentWidth: CGFloat = 0
    public private(set) var width: CGFloat = 320

    private var blockOrder: [BlockID] = []
    private var blocksByID: [BlockID: MarkdownBlock] = [:]
    private var textViews: [BlockID: TextBlockView] = [:]
    private var tableViews: [BlockID: TableBlockView] = [:]
    private var layouts: [BlockID: BlockLayoutResult] = [:]
    private var codeStates: [BlockID: CodeBlockState] = [:]
    private var elementCache: [AccessibleElementModel.ID: LiveFrameAccessibilityElement] = [:]
    /// One `.list` accessibility container per list block, cached so VoiceOver
    /// focus and the announced list boundaries survive streaming updates.
    private var listContainerCache: [BlockID: ListAccessibilityElement] = [:]
    /// The last height delivered through `onContentHeightChange`; nil when
    /// nothing authoritative has been reported since the last reset or width
    /// change.
    private var lastReportedHeight: CGFloat?
    /// The last width delivered through `onContentWidthChange`.
    private var lastReportedWidth: CGFloat?

    private struct CodeBlockState {
        let document: CodeBlockDocument
        let engine: CodeBlockLayoutEngine
        let view: CodeBlockView
        var appliedBody: String
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MessageBlockContainerView does not support NSCoder")
    }

    // MARK: - Inputs

    public func updateWidth(_ newWidth: CGFloat) {
        guard newWidth > 0, newWidth != width else { return }
        width = newWidth
        // Committed layouts belong to the old width: drop them so stacking
        // never treats stale-width sizes as authoritative. The views keep
        // drawing their last commit until re-requested commits at the new
        // width bucket arrive (the commit gate now accepts them, since it
        // compares against the updated width).
        layouts = [:]
        lastReportedHeight = nil
        lastReportedWidth = nil
        restack()
    }

    /// Clears all content and per-block state — cell reuse entry point.
    public func reset() {
        for view in textViews.values { view.removeFromSuperview() }
        for view in tableViews.values { view.removeFromSuperview() }
        for state in codeStates.values { state.view.removeFromSuperview() }
        blockOrder = []
        blocksByID = [:]
        textViews = [:]
        tableViews = [:]
        layouts = [:]
        codeStates = [:]
        elementCache = [:]
        listContainerCache = [:]
        accessibilityElements = []
        contentHeight = 0
        contentWidth = 0
        lastReportedHeight = nil
        lastReportedWidth = nil
        invalidateIntrinsicContentSize()
    }

    /// Applies a document delta (or a subscribe-time snapshot). Prunes views
    /// for departed blocks, creates views for new ones, and streams code
    /// content into the line documents.
    public func apply(_ delta: DocumentDelta) {
        let document = delta.document
        blockOrder = document.blocks.map(\.id)
        let liveIDs = Set(blockOrder)

        for id in blocksByID.keys where !liveIDs.contains(id) {
            removeBlock(id)
        }
        for block in document.blocks {
            blocksByID[block.id] = block
            if case .codeBlock(let code) = block.content {
                ensureCodeBlock(block.id, code)
            } else if case .table = block.content {
                ensureTableBlock(block.id, block)
            } else if textViews[block.id] == nil {
                let view = TextBlockView(frame: .zero)
                view.managesOwnAccessibility = false // the container projects
                view.textColorOverride = foregroundColor
                addSubview(view)
                textViews[block.id] = view
            }
            // Text content itself arrives via layout commits; until then the
            // previous committed layout (if any) stays visible.
        }
        restack()
    }

    /// Applies a background layout commit. Returns false when dropped as
    /// stale (wrong revision, wrong width, or the block is gone).
    @discardableResult
    public func commit(_ commit: BlockLayoutScheduler.Commit) -> Bool {
        let id = commit.key.blockID
        guard let block = blocksByID[id],
              block.revision == commit.key.blockRevision,
              commit.key.widthBucket == RenderCacheKey.widthBucket(for: width)
        else { return false }
        if let tableView = tableViews[id] {
            layouts[id] = commit.result
            tableView.commit(commit.result)
            restack()
            return true
        }
        guard let view = textViews[id] else { return false }
        layouts[id] = commit.result
        view.commit(commit.result)
        restack()
        return true
    }

    // MARK: - Code blocks

    private func ensureCodeBlock(_ id: BlockID, _ code: CodeBlockContent) {
        if var state = codeStates[id] {
            if let delta = CodeStreamReconciler.applySnapshot(
                rawText: code.rawText,
                appliedBody: &state.appliedBody,
                document: state.document
            ) {
                state.view.documentDidAppend(delta)
            } else {
                // Content diverged (reparse rewrote the block): rebuild.
                let body = CodeStreamReconciler.canonicalBody(code.rawText)
                state.document.reset(to: body)
                state.appliedBody = body
                state.view.documentDidReset()
            }
            state.view.setStreaming(!code.isClosed)
            codeStates[id] = state
        } else {
            let body = CodeStreamReconciler.canonicalBody(code.rawText)
            let document = CodeBlockDocument(text: body)
            let engine = CodeBlockLayoutEngine(
                document: document,
                fontName: metrics.codeFontName,
                fontSize: metrics.codeFontSize
            )
            let view = CodeBlockView(
                engine: engine,
                language: code.languageHint,
                accessibilityGroupingLineThreshold: metrics.codeAccessibilityGroupingLineThreshold
            )
            view.setStreaming(!code.isClosed)
            view.onAccessibilityEscape = { [weak self, weak view] in
                guard let self, let view else { return false }
                return self.moveAccessibilityFocus(after: view)
            }
            addSubview(view)
            codeStates[id] = CodeBlockState(
                document: document, engine: engine, view: view, appliedBody: body
            )
        }
    }

    // MARK: - Tables

    /// Wide tables scroll horizontally in their own view (natural column widths,
    /// never squished), so — like code blocks — they are a non-`TextBlockView`
    /// slot with their own accessibility container.
    private func ensureTableBlock(_ id: BlockID, _ block: MarkdownBlock) {
        if let existing = tableViews[id] {
            existing.setBlock(block) // reparse may have rewritten the cells
            return
        }
        let view = TableBlockView(block: block)
        view.onLinkActivate = { [weak self] destination in
            self?.onLinkActivate?(destination) ?? false
        }
        view.onAccessibilityEscape = { [weak self, weak view] in
            guard let self, let view else { return false }
            return self.moveAccessibilityFocus(after: view)
        }
        addSubview(view)
        tableViews[id] = view
    }

    private func removeBlock(_ id: BlockID) {
        textViews[id]?.removeFromSuperview()
        textViews[id] = nil
        tableViews[id]?.removeFromSuperview()
        tableViews[id] = nil
        codeStates[id]?.view.removeFromSuperview()
        codeStates[id] = nil
        blocksByID[id] = nil
        layouts[id] = nil
        elementCache = elementCache.filter { $0.key.blockID != id }
    }

    // MARK: - Stacking

    private func restack() {
        var y: CGFloat = 0
        // Widest drawn block — code blocks fill the width; tables clamp to it;
        // prose contributes its tight width. This is what the bubble hugs.
        var maxBlockWidth: CGFloat = 0
        for (index, id) in blockOrder.enumerated() {
            if index > 0 { y += metrics.blockSpacing }
            if let state = codeStates[id] {
                let height = MessageStacking.codeBlockHeight(
                    lineCount: state.document.lineCount,
                    lineHeight: state.engine.lineHeight,
                    metrics: metrics
                )
                state.view.frame = CGRect(x: 0, y: y, width: width, height: height)
                y += height
                maxBlockWidth = max(maxBlockWidth, width)
            } else if let tableView = tableViews[id] {
                let size = layouts[id]?.size ?? CGSize(width: width, height: metrics.estimatedBlockHeight)
                // Clamp the visible frame to the viewport; the table scrolls
                // horizontally within it when its natural width is wider.
                let frameWidth = min(size.width, width)
                tableView.frame = CGRect(x: 0, y: y, width: frameWidth, height: size.height)
                y += size.height
                maxBlockWidth = max(maxBlockWidth, frameWidth)
            } else if let view = textViews[id] {
                let size = layouts[id]?.size ?? CGSize(width: width, height: metrics.estimatedBlockHeight)
                view.frame = CGRect(x: 0, y: y, width: size.width, height: size.height)
                y += size.height
                maxBlockWidth = max(maxBlockWidth, min(size.width, width))
            }
        }
        let newHeight = max(0, y)
        rebuildAccessibilityElements()
        if newHeight != contentHeight {
            contentHeight = newHeight
            invalidateIntrinsicContentSize()
        }
        // Content width drives bubble hugging only (no list geometry), so it is
        // reported eagerly — no authoritative-layout gate.
        if maxBlockWidth != contentWidth {
            contentWidth = maxBlockWidth
        }
        if lastReportedWidth != maxBlockWidth {
            lastReportedWidth = maxBlockWidth
            onContentWidthChange?(maxBlockWidth)
        }
        // Report only authoritative heights: while any non-code block still
        // stacks at `estimatedBlockHeight` the total is a guess, and feeding
        // it to the host would clobber the exact measured height (visible
        // collapse/re-expand on every bind). Once every block has a committed
        // layout, a genuinely-changed height still propagates — the self-heal
        // property is preserved.
        if hasAuthoritativeLayouts, lastReportedHeight != newHeight {
            lastReportedHeight = newHeight
            onContentHeightChange?(newHeight)
        }
    }

    /// True when every non-code block has a committed layout at the current
    /// width, i.e. the stacked height contains no estimates. (Code blocks are
    /// always exact: they are sized by line count, never estimated.) An empty
    /// container is never authoritative: bind-time restacks before the
    /// snapshot arrives must not report height 0 for a message that has
    /// content.
    private var hasAuthoritativeLayouts: Bool {
        !blockOrder.isEmpty && blockOrder.allSatisfy { codeStates[$0] != nil || layouts[$0] != nil }
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: contentHeight)
    }

    // MARK: - Accessibility projection

    /// Rebuilds the ordered element list from the same blocks and layouts
    /// that drive drawing. Element *instances* are cached by stable ID, so a
    /// streaming update refreshes labels/frames in place and VoiceOver focus
    /// survives; code views participate directly as containers.
    private func rebuildAccessibilityElements() {
        RenderSignposts.list.withIntervalSignpost("accessibility.project") {
            rebuildAccessibilityElementsBody()
        }
    }

    private func rebuildAccessibilityElementsBody() {
        var output: [Any] = []
        // Links in reading order, fed to the `.link` system rotor below. The
        // built-in Links rotor only auto-populates for web/UITextView content,
        // so custom accessibility elements must supply it explicitly even
        // though each already carries the `.link` trait.
        var links: [LinkAccessibilityElement] = []
        // Every focusable leaf element, so the Links rotor can be attached to
        // each one. Custom rotors are read from the *focused* element, not
        // inherited from its container — attach only to the container and
        // VoiceOver reverts to the Characters rotor whenever focus lands on a
        // non-link element that doesn't carry the rotor.
        var leaves: [LiveFrameAccessibilityElement] = []
        for id in blockOrder {
            if let state = codeStates[id] {
                output.append(state.view)
                continue
            }
            if let tableView = tableViews[id] {
                output.append(tableView)
                continue
            }
            guard let block = blocksByID[id],
                  let layout = layouts[id],
                  let view = textViews[id]
            else { continue }
            // Wrap a list block's per-item elements in a `.list` container so
            // VoiceOver announces "list start"/"list end" around the bullets on
            // its own, and each bullet stays a single focusable row (its element
            // spans the item's full, possibly multi-line, frame). Links inside
            // a list stay inside that container as their own rows; a paragraph
            // body and its links are appended flat.
            var listRows: [LiveFrameAccessibilityElement] = []
            for model in AccessibilityProjector.elements(for: block, layout: layout, origin: view.frame.origin) {
                let el = element(for: model)
                leaves.append(el)
                if let link = el as? LinkAccessibilityElement { links.append(link) }
                switch model.id.slot {
                case .listItem:
                    listRows.append(el)
                    continue
                case .link where !listRows.isEmpty:
                    // A link interleaved after a list item belongs to the list
                    // we're building — keep it inside the container so the list
                    // stays a single "list start"/"list end" run, with the link
                    // still its own focusable row right after its item.
                    listRows.append(el)
                    continue
                default:
                    break
                }
                if !listRows.isEmpty {
                    output.append(listContainer(for: id, rows: listRows))
                    listRows = []
                }
                output.append(el)
            }
            if !listRows.isEmpty {
                output.append(listContainer(for: id, rows: listRows))
            }
        }
        // Element instances are cached and updated in place; reassigning the
        // array invalidates the AX tree, so skip it when the sequence hasn't
        // changed (it usually hasn't during streaming — this is what made
        // enabling VoiceOver mid-stream feel slow).
        let changed = output.count != (accessibilityElements?.count ?? -1)
            || !zip(output, accessibilityElements ?? []).allSatisfy { ($0 as AnyObject) === ($1 as AnyObject) }
        if changed {
            accessibilityElements = output
            // Rebuild captures a fresh `links` snapshot; reassign the rotor to
            // every current leaf so reused elements drop any stale capture.
            let rotors = links.isEmpty ? nil : [linkRotor(over: leaves)]
            accessibilityCustomRotors = rotors
            for leaf in leaves { leaf.accessibilityCustomRotors = rotors }
        }
    }

    /// A `.link` system rotor that steps through this message's links in
    /// reading order, so VoiceOver's "Links" rotor works over our custom
    /// accessibility elements. It searches `leaves` — every focusable element
    /// in reading order, links included — rather than a links-only array, so
    /// that flicking from a non-link element lands on the next/previous link
    /// relative to the current reading position, not on the first/last link
    /// in the message. The array is captured per rebuild, so a later rebuild
    /// replaces the rotor with a fresh, current snapshot.
    private func linkRotor(over leaves: [LiveFrameAccessibilityElement]) -> UIAccessibilityCustomRotor {
        UIAccessibilityCustomRotor(systemType: .link) { predicate in
            let forward = predicate.searchDirection == .next
            let current = predicate.currentItem.targetElement as AnyObject
            let index = leaves.firstIndex { $0 === current }
            // Unknown focus (e.g. inside a code block's own container): scan
            // the whole message from the appropriate end.
            let start = index.map { forward ? $0 + 1 : $0 - 1 } ?? (forward ? 0 : leaves.count - 1)
            var next = start
            while next >= 0, next < leaves.count {
                if let link = leaves[next] as? LinkAccessibilityElement {
                    return UIAccessibilityCustomRotorItemResult(targetElement: link, targetRange: nil)
                }
                next += forward ? 1 : -1
            }
            return nil
        }
    }

    /// Escape target for a nested scroll region (code block): the projected
    /// element right after it, so VoiceOver focus leaves the region and
    /// three-finger swipes scroll the conversation again.
    private func moveAccessibilityFocus(after view: UIView) -> Bool {
        guard let elements = accessibilityElements,
              let index = elements.firstIndex(where: { ($0 as AnyObject) === view })
        else { return false }
        let target: Any?
        if index + 1 < elements.count {
            target = elements[index + 1]
        } else if index > 0 {
            target = elements[index - 1]
        } else {
            target = nil
        }
        guard let target else { return false }
        UIAccessibility.post(notification: .layoutChanged, argument: target)
        return true
    }

    private func element(for model: AccessibleElementModel) -> LiveFrameAccessibilityElement {
        let element: LiveFrameAccessibilityElement
        if let cached = elementCache[model.id] {
            element = cached
        } else {
            switch model.kind {
            case .blockText:
                element = LiveFrameAccessibilityElement(accessibilityContainer: self)
            case .link:
                let linkElement = LinkAccessibilityElement(accessibilityContainer: self)
                linkElement.activateHandler = { [weak self] destination in
                    self?.onLinkActivate?(destination) ?? false
                }
                element = linkElement
            }
            element.referenceView = self
            elementCache[model.id] = element
        }
        element.accessibilityLabel = model.label
        element.localFrame = model.frame
        switch model.kind {
        case .blockText(let role):
            if case .heading = role {
                element.accessibilityTraits = [.staticText, .header]
            } else {
                element.accessibilityTraits = .staticText
            }
        case .link(let destination):
            element.accessibilityTraits = .link
            element.accessibilityHint = destination
            (element as? LinkAccessibilityElement)?.destination = destination
        }
        return element
    }

    /// A cached `.list` accessibility container wrapping one list block's item
    /// rows. `accessibilityContainerType = .list` is what makes VoiceOver speak
    /// the list boundaries; the container is non-focusable itself and just holds
    /// the rows. Reused per block so streaming refreshes its rows in place.
    private func listContainer(for blockID: BlockID, rows: [LiveFrameAccessibilityElement]) -> ListAccessibilityElement {
        let container: ListAccessibilityElement
        if let cached = listContainerCache[blockID] {
            container = cached
        } else {
            container = ListAccessibilityElement(accessibilityContainer: self)
            container.referenceView = self
            listContainerCache[blockID] = container
        }
        container.accessibilityElements = rows
        let frame = rows.reduce(CGRect.null) { $0.union($1.localFrame) }
        if !frame.isNull {
            container.localFrame = frame
        }
        return container
    }

    // MARK: - Link taps

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        for view in textViews.values {
            let point = gesture.location(in: view)
            guard view.bounds.contains(point) else { continue }
            if let destination = view.linkDestination(at: point) {
                _ = onLinkActivate?(destination)
            }
            return
        }
    }
}

/// A focusable, activatable link element. Destination is mutable because the
/// element instance is reused across streaming updates of the same slot.
final class LinkAccessibilityElement: LiveFrameAccessibilityElement {
    var destination: String = ""
    var activateHandler: ((String) -> Bool)?

    override func accessibilityActivate() -> Bool {
        activateHandler?(destination) ?? false
    }
}

/// Non-focusable `.list` container for one markdown list block. Its children
/// are the per-item elements; VoiceOver announces "list start"/"list end" as
/// focus enters and leaves it, with no per-message wiring at the call site.
final class ListAccessibilityElement: LiveFrameAccessibilityElement {
    override init(accessibilityContainer container: Any) {
        super.init(accessibilityContainer: container)
        isAccessibilityElement = false
        accessibilityContainerType = .list
    }
}
#endif
