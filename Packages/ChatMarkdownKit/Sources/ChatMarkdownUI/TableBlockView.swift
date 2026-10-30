#if canImport(UIKit)
import UIKit
import ChatMarkdownCore
import ChatTextLayout

/// Horizontally scrollable host for a Markdown table.
///
/// Tables are laid out at their natural (unwrapped) column widths — never
/// squished to the bubble — so a wide table exceeds the message width. This
/// view carries the table bitmap (an inner `TextBlockView`, reused for its
/// async, generation-gated rasterization) and scrolls it horizontally when it
/// is wider than the viewport, instead of clipping or truncating columns.
///
/// Accessibility: like `CodeBlockView`, this is its own container rather than
/// one opaque element. VoiceOver sees a body element carrying the spoken table
/// description (pinned to the visible edge so touch exploration always finds
/// it) followed by any link elements, plus a three-finger horizontal scroll and
/// a two-finger-scrub escape so focus can leave the scroll region.
public final class TableBlockView: UIScrollView {
    /// VoiceOver escape: the container moves focus to the element after this
    /// block so three-finger swipes scroll the *conversation* again.
    public var onAccessibilityEscape: (() -> Bool)?
    /// Link activation (tap or VoiceOver activate). Destination is the RAW
    /// string from the Markdown source — validate before opening.
    public var onLinkActivate: ((String) -> Bool)?

    private let content = TextBlockView(frame: .zero)
    private var layoutResult: BlockLayoutResult?
    private var block: MarkdownBlock?

    private var bodyElement: LiveFrameAccessibilityElement?
    private var linkElements: [Int: LinkAccessibilityElement] = [:]

    public init(block: MarkdownBlock) {
        self.block = block
        super.init(frame: .zero)
        content.managesOwnAccessibility = false // this view projects instead
        addSubview(content)
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        clipsToBounds = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        refreshAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TableBlockView does not support NSCoder")
    }

    /// The block this view renders, so accessibility projection can reuse the
    /// shared `AccessibilityProjector`. Updated when a reparse rewrites it.
    public func setBlock(_ block: MarkdownBlock) {
        self.block = block
    }

    /// Main-thread commit of a background-produced table layout. The inner
    /// bitmap view revision-checks upstream; here we size the scrollable
    /// content to the table's natural width.
    public func commit(_ result: BlockLayoutResult) {
        layoutResult = result
        content.frame = CGRect(origin: .zero, size: result.size)
        content.commit(result)
        contentSize = result.size
        refreshAccessibility()
    }

    // MARK: - Link taps

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // The inner view sits at content origin; `location(in:)` already
        // accounts for the scroll offset.
        let point = gesture.location(in: content)
        if let destination = content.linkDestination(at: point) {
            _ = onLinkActivate?(destination)
        }
    }

    // MARK: - Accessibility container

    private func refreshAccessibility() {
        isAccessibilityElement = false
        guard let layoutResult, let block else {
            accessibilityElements = []
            return
        }

        let models = AccessibilityProjector.elements(
            for: block, layout: layoutResult, origin: .zero
        )
        var output: [Any] = []
        var liveLinks = Set<Int>()

        for model in models {
            switch model.id.slot {
            case .body:
                let body: LiveFrameAccessibilityElement
                if let existing = bodyElement {
                    body = existing
                } else {
                    body = LiveFrameAccessibilityElement(accessibilityContainer: self)
                    body.referenceView = self
                    body.accessibilityTraits = .staticText
                    body.accessibilityCustomActions = [
                        UIAccessibilityCustomAction(name: "Leave table") { [weak self] _ in
                            self?.onAccessibilityEscape?() ?? false
                        }
                    ]
                    bodyElement = body
                }
                body.accessibilityLabel = model.label
                body.accessibilityHint =
                    "Three-finger swipe to scroll. Two-finger scrub to leave the table."
                // Pinned to the visible left edge (container space pans with the
                // content offset) so touch exploration finds it at any scroll.
                body.localFrame = CGRect(
                    origin: contentOffset,
                    size: CGSize(width: max(bounds.width, 44), height: max(bounds.height, 24))
                )
                output.append(body)
            case .link(let index):
                guard case .link(let destination) = model.kind else { continue }
                liveLinks.insert(index)
                let element: LinkAccessibilityElement
                if let cached = linkElements[index] {
                    element = cached
                } else {
                    let link = LinkAccessibilityElement(accessibilityContainer: self)
                    link.referenceView = self
                    link.accessibilityTraits = .link
                    link.activateHandler = { [weak self] destination in
                        self?.onLinkActivate?(destination) ?? false
                    }
                    linkElements[index] = link
                    element = link
                }
                element.accessibilityLabel = model.label
                element.accessibilityHint = destination
                element.destination = destination
                element.localFrame = model.frame
                output.append(element)
            case .listItem:
                // Tables project only a body element and per-cell links; list
                // items are never emitted for a table block.
                continue
            }
        }
        linkElements = linkElements.filter { liveLinks.contains($0.key) }

        // Reassigning invalidates the AX tree; skip when the sequence is
        // unchanged (element instances are cached and updated in place).
        let changed = output.count != (accessibilityElements?.count ?? -1)
            || !zip(output, accessibilityElements ?? []).allSatisfy { ($0 as AnyObject) === ($1 as AnyObject) }
        if changed {
            accessibilityElements = output
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // The pinned body frame tracks the visible edge as the table scrolls.
        refreshAccessibility()
    }

    /// VoiceOver two-finger scrub.
    public override func accessibilityPerformEscape() -> Bool {
        onAccessibilityEscape?() ?? false
    }

    /// Three-finger VoiceOver scrolling: page horizontally. Direction follows
    /// the finger (swipe left reveals content to the right).
    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let page = max(bounds.width * 0.8, 1)
        let maxX = max(0, contentSize.width - bounds.width)
        var target = contentOffset
        switch direction {
        case .left:
            target.x = min(maxX, contentOffset.x + page)
        case .right:
            target.x = max(0, contentOffset.x - page)
        default:
            return false
        }
        guard target != contentOffset else { return false }
        setContentOffset(target, animated: false)
        refreshAccessibility()
        return true
    }
}
#endif
