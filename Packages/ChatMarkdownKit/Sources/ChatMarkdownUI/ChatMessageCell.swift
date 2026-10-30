#if canImport(UIKit)
import UIKit
import ChatMarkdownCore
import ChatTextLayout

/// Bridges one `MessageStreamRenderer` to one `MessageBlockContainerView`:
/// subscribes on the main actor, applies document deltas and layout commits
/// as they arrive, and tears down cleanly on cancel.
///
/// Each binding owns an independent subscription (streams are multicast with
/// snapshot catch-up), so rebinding after cell reuse is always safe.
@MainActor
public final class MessageRenderBinding {
    private var task: Task<Void, Never>?

    public init(renderer: MessageStreamRenderer, container: MessageBlockContainerView) {
        task = Task { [weak container] in
            let events = await renderer.subscribe()
            for await event in events {
                guard let container, !Task.isCancelled else { break }
                switch event {
                case .document(let delta):
                    container.apply(delta)
                case .layout(let commit):
                    container.commit(commit)
                }
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

/// Collection view cell hosting one message. Reuse protocol: `bind(to:)`
/// cancels the previous subscription, resets the container, and subscribes
/// fresh — the renderer's snapshot catch-up rebuilds current content, and
/// the container's revision/width gates drop anything stale in flight.
public final class ChatMessageCell: UICollectionViewCell {
    /// The bubble chrome (background, corner radius, border). The message
    /// content is drawn inside it, inset by the style's content insets.
    public let bubbleView = UIView(frame: .zero)
    public let messageView = MessageBlockContainerView(frame: .zero)
    private var binding: MessageRenderBinding?

    /// Reports the message's full height (content + vertical bubble insets) so
    /// the controller can update list geometry. Set by the controller.
    public var onHeightChange: ((CGFloat) -> Void)?

    private var style = BubbleStyle(backgroundColor: .clear, cornerRadius: 0, maxWidth: .fill)
    /// The widest the bubble content may become (layout/wrapping width). The
    /// bubble hugs `min(natural content width, this)`.
    private var maxContentWidth: CGFloat = 0
    /// Current hugged content width, driven by the container mid-stream. Starts
    /// at the max so a not-yet-measured bubble fills, then hugs down.
    private var bubbleContentWidth: CGFloat = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        // Manual layout: the collection view assigns exact frames from
        // precomputed geometry, so the cell frames its own bubble + content.
        contentView.addSubview(bubbleView)
        bubbleView.addSubview(messageView)
        bubbleView.layer.masksToBounds = true

        messageView.onContentWidthChange = { [weak self] naturalWidth in
            guard let self else { return }
            self.bubbleContentWidth = min(naturalWidth, self.maxContentWidth)
            self.setNeedsLayout()
        }
        messageView.onContentHeightChange = { [weak self] height in
            guard let self else { return }
            self.onHeightChange?(ceil(height) + self.style.verticalInsets)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChatMessageCell does not support NSCoder")
    }

    /// Applies the bubble appearance and the content (wrapping) width ceiling.
    public func configure(style: BubbleStyle, maxContentWidth: CGFloat) {
        self.style = style
        self.maxContentWidth = maxContentWidth
        // Until the container reports a natural width, fill to the max.
        self.bubbleContentWidth = maxContentWidth
        messageView.foregroundColor = style.foregroundColor
        bubbleView.layer.cornerRadius = style.cornerRadius
        bubbleView.layer.borderWidth = style.borderWidth
        applyBubbleColors()
        setNeedsLayout()
    }

    public func bind(to renderer: MessageStreamRenderer, width: CGFloat) {
        RenderSignposts.list.withIntervalSignpost("cell.bind") {
            binding?.cancel()
            messageView.reset()
            messageView.updateWidth(width)
            binding = MessageRenderBinding(renderer: renderer, container: messageView)
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let bubbleWidth = min(bounds.width, bubbleContentWidth + style.horizontalInsets)
        let x = style.alignment == .trailing ? bounds.width - bubbleWidth : 0
        bubbleView.frame = CGRect(x: x, y: 0, width: bubbleWidth, height: bounds.height)
        messageView.frame = bubbleView.bounds.inset(by: style.contentInsets)
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            applyBubbleColors()
        }
    }

    private func applyBubbleColors() {
        bubbleView.backgroundColor = style.backgroundColor
        bubbleView.layer.borderColor = style.borderColor.resolvedColor(with: traitCollection).cgColor
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        binding?.cancel()
        binding = nil
        onHeightChange = nil
        messageView.reset()
    }
}
#endif
