#if canImport(UIKit)
import UIKit
import ChatMarkdownCore
import ChatTextLayout

/// Displays one immutable `BlockLayoutResult` as an asynchronously rendered
/// bitmap. The main thread never rasterizes: `commit(_:)` snapshots the
/// current palette and kicks a background `BlockBitmapRenderer` pass; the
/// finished image lands in `layer.contents`, gated by a generation counter
/// so a stale render can never overwrite a newer one.
///
/// During streaming updates the previous bitmap stays visible until its
/// replacement arrives (anchored top-left, never stretched) — text grows
/// in place instead of flashing.
public final class TextBlockView: UIView {
    private var layoutResult: BlockLayoutResult?
    /// Bumped on every commit, trait change, and reuse; async renders apply
    /// only if their generation is still current.
    private var renderGeneration: UInt64 = 0

    /// Text/link tint override (`nil` ⇒ system `UIColor.label` / `.link`). Set
    /// by the container from the bubble style; re-renders the cached geometry.
    public var textColorOverride: UIColor? {
        didSet {
            guard textColorOverride != oldValue else { return }
            scheduleRender()
        }
    }

    /// True (default) when the view stands alone and exposes itself as one
    /// accessibility element. `MessageBlockContainerView` sets this false and
    /// projects finer-grained elements (body + individual links) itself.
    public var managesOwnAccessibility = true {
        didSet {
            if !managesOwnAccessibility {
                isAccessibilityElement = false
            }
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        // Bitmap contents, not draw(_:): no UIKit backing store exists for
        // this view at all. Top-left gravity keeps the old bitmap anchored
        // (not stretched) while a growing block waits for its next render.
        layer.contentsGravity = .topLeft
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TextBlockView does not support NSCoder")
    }

    /// Main-thread commit of a background-produced layout snapshot. Callers
    /// (block containers) revision-check against their current block before
    /// committing; a stale snapshot must be dropped, not committed.
    public func commit(_ result: BlockLayoutResult) {
        layoutResult = result
        applyAccessibility(result.accessibility)
        invalidateIntrinsicContentSize()
        scheduleRender()
    }

    public var committedResult: BlockLayoutResult? { layoutResult }

    public override var intrinsicContentSize: CGSize {
        layoutResult?.size ?? .zero
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Colors are resolved at render time, so appearance changes re-render
        // the same cached geometry; layout is untouched.
        let colorsChanged = traitCollection.hasDifferentColorAppearance(
            comparedTo: previousTraitCollection
        )
        let scaleChanged = traitCollection.displayScale != previousTraitCollection?.displayScale
        if colorsChanged || scaleChanged {
            scheduleRender()
        }
    }

    private func scheduleRender() {
        renderGeneration &+= 1
        guard let result = layoutResult else {
            layer.contents = nil
            return
        }
        let generation = renderGeneration
        let textColor = (textColorOverride ?? .label).resolvedColor(with: traitCollection).cgColor
        let palette = DrawPalette(
            text: textColor,
            rule: UIColor.separator.resolvedColor(with: traitCollection).cgColor,
            quoteBar: UIColor.systemFill.resolvedColor(with: traitCollection).cgColor,
            link: (textColorOverride ?? .link).resolvedColor(with: traitCollection).cgColor
        )
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = BlockBitmapRenderer.render(result: result, palette: palette, scale: scale)
            guard let image else { return }
            await MainActor.run { [weak self] in
                guard let self, self.renderGeneration == generation else { return }
                self.layer.contents = image
                self.layer.contentsScale = scale
            }
        }
    }

    /// Block-local hit test for links (view coordinates == block-local
    /// coordinates). The interaction layer builds tap handling on this.
    public func linkDestination(at point: CGPoint) -> String? {
        guard let layoutResult else { return nil }
        for link in layoutResult.links {
            for rect in link.rects where rect.insetBy(dx: -4, dy: -4).contains(point) {
                return link.destination
            }
        }
        return nil
    }

    // Standalone accessibility: one element per block with role-appropriate
    // traits. Inside a message container this is disabled and the container's
    // projection (body + per-link elements) takes over.
    private func applyAccessibility(_ accessibility: BlockAccessibility) {
        guard managesOwnAccessibility else {
            isAccessibilityElement = false
            return
        }
        isAccessibilityElement = true
        accessibilityLabel = accessibility.label
        switch accessibility.role {
        case .heading:
            accessibilityTraits = [.staticText, .header]
        case .paragraph, .quote, .list, .table, .code, .rule, .html:
            accessibilityTraits = .staticText
        }
    }
}
#endif
