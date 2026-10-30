#if canImport(UIKit)
import UIKit
import ChatMarkdownCore
import ChatTextLayout

/// The conversation list: a `UICollectionView` of `ChatMessageCell`s over
/// exact, precomputed heights.
///
/// Height pipeline: every message gets a watcher that measures its document
/// through `scheduler.measuredContentHeight` (off-main, warming the shared
/// layout cache) and keeps measuring on document deltas until the stream
/// completes. Heights land in a store; geometry rebuilds; the offset is
/// adjusted by `ChatScrollPolicy` — pinned to the bottom while following,
/// anchor-compensated while reading history.
///
/// Memory: heights are retained for every message (a CGFloat each); full
/// layout results live in the scheduler's LRU and are additionally released
/// for messages far outside the viewport when scrolling idles.
@MainActor
public final class ChatConversationViewController: UIViewController {
    public let scheduler: BlockLayoutScheduler
    public var theme: TextTheme
    public var environment = RenderEnvironment()
    public var metrics = MessageLayoutMetrics()
    /// Per-sender bubble appearance (color, corner radius, border, padding,
    /// max width, alignment). Set before messages are appended; changing it
    /// afterward requires a re-measure/reload to take full effect.
    public var bubbleAppearance = BubbleAppearance()
    /// Viewport-relative range policy: messages outside the preload band get
    /// their layout caches released on scroll idle; released messages
    /// re-entering the band are rewarmed before they can scroll on screen.
    /// (A message *count* would be meaningless — one message can be 24 points
    /// tall and the next 12,000.)
    public var rangePolicy = MessageRangePolicy()
    /// Validated link activation — destinations have already passed
    /// `SafeLinkPolicy`.
    public var onOpenLink: ((URL) -> Void)?
    /// Which schemes a tapped link may carry to be opened; `.standard`
    /// (http/https/mailto) by default. Opt in with `.allow(…)` or
    /// `.anyExceptDangerous` to make app deep links tappable. The markdown is
    /// untrusted — a permissive policy means arbitrary content can invoke any
    /// installed app's URL handler when the user taps.
    public var linkSchemePolicy: SafeLinkPolicy.SchemePolicy = .standard

    public private(set) var isFollowingBottom = true
    public private(set) var collectionView: UICollectionView!

    private let listLayout = ChatListLayout()
    private var messageIDs: [MessageID] = []
    private var renderers: [MessageID: MessageStreamRenderer] = [:]
    private var measuredHeights: [MessageID: CGFloat] = [:]
    /// Watchers are tagged with a generation so a cancelled watcher's tail
    /// cleanup can never delete its successor's entry.
    private var heightWatchers: [MessageID: (generation: UInt64, task: Task<Void, Never>)] = [:]
    private var heightWatcherGeneration: UInt64 = 0
    /// Messages whose layout caches were released as `.cold`; rewarmed when
    /// they re-enter the preload band.
    private var releasedMessages: Set<MessageID> = []
    /// Points/second from the last drag end — biases the range bands toward
    /// the fling direction.
    private var lastDragVelocityY: CGFloat = 0
    private var isAdjustingOffsetProgrammatically = false
    private var lastLaidOutWidthBucket = 0

    private static let cellReuseIdentifier = "ChatMessageCell"

    public init(scheduler: BlockLayoutScheduler = BlockLayoutScheduler(), theme: TextTheme = .default) {
        self.scheduler = scheduler
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChatConversationViewController does not support NSCoder")
    }

    deinit {
        for watcher in heightWatchers.values { watcher.task.cancel() }
    }

    // MARK: - Lifecycle

    public override func loadView() {
        listLayout.horizontalInset = metrics.horizontalInset
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: listLayout)
        collectionView.backgroundColor = .systemBackground
        collectionView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ChatMessageCell.self, forCellWithReuseIdentifier: Self.cellReuseIdentifier)
        self.collectionView = collectionView
        view = collectionView
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bucket = RenderCacheKey.widthBucket(for: availableWidth)
        if bucket != lastLaidOutWidthBucket {
            lastLaidOutWidthBucket = bucket
            remeasureAllForWidthChange()
        }
    }

    // MARK: - Public API

    /// Appends a message and takes over its height tracking. Pass renderers
    /// created with this controller's `scheduler` so layout caches are shared.
    ///
    /// Safe to call before the view is loaded — the view is loaded on demand.
    public func append(_ renderer: MessageStreamRenderer) {
        loadViewIfNeeded()
        let id = renderer.messageID
        messageIDs.append(id)
        renderers[id] = renderer
        syncRendererEnvironment(renderer)

        rebuildGeometryAndAdjust()
        let indexPath = IndexPath(item: messageIDs.count - 1, section: 0)
        if collectionView.window != nil {
            UIView.performWithoutAnimation {
                collectionView.insertItems(at: [indexPath])
            }
        } else {
            collectionView.reloadData()
        }
        startHeightWatcher(for: renderer)
    }

    /// Replaces the whole conversation (initial load).
    ///
    /// Safe to call before the view is loaded — the view is loaded on demand.
    public func setMessages(_ newRenderers: [MessageStreamRenderer]) {
        loadViewIfNeeded()
        for watcher in heightWatchers.values { watcher.task.cancel() }
        heightWatchers = [:]
        measuredHeights = [:]
        messageIDs = newRenderers.map(\.messageID)
        renderers = Dictionary(uniqueKeysWithValues: newRenderers.map { ($0.messageID, $0) })
        isFollowingBottom = true

        releasedMessages = []
        rebuildGeometryAndAdjust()
        collectionView.reloadData()
        for renderer in newRenderers {
            syncRendererEnvironment(renderer)
            startHeightWatcher(for: renderer)
        }
    }

    public func renderer(for id: MessageID) -> MessageStreamRenderer? {
        renderers[id]
    }

    // MARK: - Height pipeline

    /// Viewport width minus the list's horizontal inset — the widest a bubble
    /// (including its own content insets) may become.
    private var availableWidth: CGFloat {
        // The view is always loaded before this runs (append/setMessages call
        // loadViewIfNeeded), but it may not have been laid out yet — fall
        // back to a nominal width until the first layout pass, which then
        // triggers a width-bucket remeasure.
        let boundsWidth = collectionView.bounds.width
        return max(1, (boundsWidth > 0 ? boundsWidth : 320) - metrics.horizontalInset * 2)
    }

    /// The content (text-wrapping) width for a sender: the bubble's max width
    /// minus its content insets. This is the width every part of the pipeline
    /// lays out at — measurement, the renderer, and the cell's container — so
    /// heights stay exact. The bubble then hugs its content down from here.
    private func maxContentWidth(for sender: MessageSender) -> CGFloat {
        let style = bubbleAppearance.style(for: sender)
        let available = availableWidth
        let bubbleMax = min(available, style.maxWidth.resolve(available: available))
        return max(1, bubbleMax - style.horizontalInsets)
    }

    private func sender(for id: MessageID) -> MessageSender {
        renderers[id]?.sender ?? .assistant
    }

    /// Measures now, then keeps measuring on document deltas until the
    /// stream completes. Measurement goes through the scheduler's cache, so
    /// the work is shared with the cell that eventually displays the blocks.
    private func startHeightWatcher(for renderer: MessageStreamRenderer) {
        let id = renderer.messageID
        heightWatchers[id]?.task.cancel()
        heightWatcherGeneration += 1
        let generation = heightWatcherGeneration
        // Self is re-acquired weakly per event, never held across the
        // stream's lifetime — the controller stays deallocatable while
        // messages stream.
        let task = Task { [weak self] in
            let document = await renderer.currentDocument()
            await self?.measureAndStore(document)
            if document.isComplete || Task.isCancelled {
                self?.endHeightWatcher(id, generation: generation)
                return
            }
            let events = await renderer.subscribe()
            for await event in events {
                if Task.isCancelled { break }
                guard case .document(let delta) = event else { continue }
                guard let self else { return }
                await self.measureAndStore(delta.document)
                if delta.document.isComplete { break }
            }
            self?.endHeightWatcher(id, generation: generation)
        }
        heightWatchers[id] = (generation, task)
    }

    /// Tail cleanup for a finishing watcher. Generation-checked so a
    /// cancelled watcher resuming late can never delete the entry of the
    /// replacement watcher that superseded it.
    private func endHeightWatcher(_ id: MessageID, generation: UInt64) {
        guard heightWatchers[id]?.generation == generation else { return }
        heightWatchers[id] = nil
    }

    private func measureAndStore(_ document: MarkdownDocument) async {
        let id = document.messageID
        let sender = sender(for: id)
        let style = bubbleAppearance.style(for: sender)
        let width = maxContentWidth(for: sender)
        let bucket = RenderCacheKey.widthBucket(for: width)
        let contentHeight = await scheduler.measuredContentHeight(
            of: document,
            width: width,
            theme: theme,
            environment: environment,
            metrics: metrics
        )
        guard !Task.isCancelled else { return }
        // The width may have changed while we were suspended (rotation racing
        // a delta); storing then would plant an old-width height into the
        // freshly cleared store. Re-measure at the current width instead.
        guard RenderCacheKey.widthBucket(for: maxContentWidth(for: sender)) == bucket else {
            await measureAndStore(document)
            return
        }
        // The stored (list geometry) height is the content plus the bubble's
        // vertical padding — the cell renders content inset by exactly this.
        setHeight(contentHeight + style.verticalInsets, for: id)
    }

    private func setHeight(_ height: CGFloat, for id: MessageID) {
        guard measuredHeights[id] != height else { return }
        measuredHeights[id] = height
        rebuildGeometryAndAdjust()
    }

    private func remeasureAllForWidthChange() {
        measuredHeights = [:]
        // Visible cells are never rebound on rotation, so push the new per-sender
        // width into their containers directly and reconfigure the bubble: the
        // container restacks and its commit gate starts accepting the new width
        // bucket (the renderers below re-request layout at that bucket via
        // syncRendererEnvironment).
        for cell in collectionView.visibleCells {
            guard let cell = cell as? ChatMessageCell,
                  let indexPath = collectionView.indexPath(for: cell),
                  indexPath.item < messageIDs.count
            else { continue }
            let sender = sender(for: messageIDs[indexPath.item])
            let width = maxContentWidth(for: sender)
            cell.configure(style: bubbleAppearance.style(for: sender), maxContentWidth: width)
            cell.messageView.updateWidth(width)
        }
        for id in messageIDs {
            guard let renderer = renderers[id] else { continue }
            syncRendererEnvironment(renderer)
            // Streaming watchers keep running with the new width on their
            // next delta; completed messages get a one-shot remeasure.
            if heightWatchers[id] == nil {
                startHeightWatcher(for: renderer)
            }
        }
        rebuildGeometryAndAdjust()
    }

    /// The controller is the width/theme authority: renderers lay out at
    /// whatever geometry they were created with, so the controller pushes its
    /// own into every renderer it hosts. Without this, commits arrive at the
    /// wrong width bucket and the container gate (correctly) drops them all.
    private func syncRendererEnvironment(_ renderer: MessageStreamRenderer) {
        let width = maxContentWidth(for: renderer.sender)
        let theme = self.theme
        let environment = self.environment
        Task {
            await renderer.updateEnvironment(width: width, theme: theme, environment: environment)
        }
    }

    // MARK: - Geometry + anchoring

    private func rebuildGeometryAndAdjust() {
        RenderSignposts.list.withIntervalSignpost("scroll.anchorAdjust") {
            rebuildGeometryAndAdjustBody()
        }
    }

    private func rebuildGeometryAndAdjustBody() {
        // The view is guaranteed loaded: every path here descends from
        // append/setMessages (which call loadViewIfNeeded) or from
        // view-lifecycle callbacks.
        let heights = messageIDs.map { measuredHeights[$0] ?? metrics.estimatedMessageHeight }
        let newGeometry = ChatListGeometry(heights: heights, spacing: metrics.interMessageSpacing)
        let oldGeometry = listLayout.geometry
        let oldOffsetY = collectionView.contentOffset.y
        let viewportHeight = collectionView.bounds.height
        let topInset = collectionView.adjustedContentInset.top
        let bottomInset = collectionView.adjustedContentInset.bottom
        let anchorIndex = oldGeometry.anchorIndex(forY: oldOffsetY + topInset)

        listLayout.geometry = newGeometry

        let compensation = ChatListGeometry.compensation(
            from: oldGeometry, to: newGeometry, anchorIndex: anchorIndex
        )
        let target = ChatScrollPolicy.targetOffsetY(
            previousOffsetY: oldOffsetY,
            anchorCompensation: compensation,
            followBottom: isFollowingBottom,
            contentHeight: newGeometry.contentHeight,
            viewportHeight: viewportHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
        if target != oldOffsetY {
            isAdjustingOffsetProgrammatically = true
            collectionView.contentOffset = CGPoint(x: 0, y: target)
            isAdjustingOffsetProgrammatically = false
        }
    }

    // MARK: - Range states

    /// Classifies every message by viewport distance (biased toward the last
    /// fling direction), releases layout caches for `.cold` messages, and
    /// rewarms previously released messages that re-entered the preload band
    /// so they bind against a warm cache when they reach the screen.
    private func applyRangeStates() {
        guard !messageIDs.isEmpty else { return }
        let states = rangePolicy.states(
            geometry: listLayout.geometry,
            viewportMinY: collectionView.contentOffset.y + collectionView.adjustedContentInset.top,
            viewportHeight: collectionView.bounds.height,
            velocity: lastDragVelocityY
        )
        lastDragVelocityY = 0

        var toRelease: [MessageID] = []
        for (index, state) in states.enumerated() {
            let id = messageIDs[index]
            if state == .cold {
                if !releasedMessages.contains(id) {
                    releasedMessages.insert(id)
                    toRelease.append(id)
                }
            } else if releasedMessages.contains(id) {
                releasedMessages.remove(id)
                rewarm(id)
            }
        }
        guard !toRelease.isEmpty else { return }
        let scheduler = scheduler
        Task.detached(priority: .utility) {
            await scheduler.releaseMessages(toRelease)
        }
    }

    /// Re-requests layout for a released message at current geometry. Cache
    /// misses recompute off-main now, so the eventual cell bind replays
    /// instantly instead of paying the miss while the user watches.
    private func rewarm(_ id: MessageID) {
        guard let renderer = renderers[id] else { return }
        let width = maxContentWidth(for: renderer.sender)
        let theme = self.theme
        let environment = self.environment
        Task(priority: .utility) {
            await renderer.updateEnvironment(width: width, theme: theme, environment: environment)
        }
    }
}

// MARK: - Data source

extension ChatConversationViewController: UICollectionViewDataSource {
    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        messageIDs.count
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: Self.cellReuseIdentifier, for: indexPath
        ) as! ChatMessageCell
        let id = messageIDs[indexPath.item]
        let sender = sender(for: id)
        let contentWidth = maxContentWidth(for: sender)
        cell.messageView.metrics = metrics
        cell.configure(style: bubbleAppearance.style(for: sender), maxContentWidth: contentWidth)
        cell.onHeightChange = { [weak self] height in
            self?.setHeight(height, for: id)
        }
        cell.messageView.onLinkActivate = { [weak self] rawDestination in
            guard let self,
                  let url = SafeLinkPolicy.validatedURL(
                      from: rawDestination,
                      policy: self.linkSchemePolicy
                  )
            else {
                return false
            }
            self.onOpenLink?(url)
            return true
        }
        if let renderer = renderers[id] {
            cell.bind(to: renderer, width: contentWidth)
        }
        return cell
    }
}

// MARK: - Scrolling

extension ChatConversationViewController: UICollectionViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjustingOffsetProgrammatically else { return }
        // Follow state tracks where the *user* put the viewport.
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        isFollowingBottom = ChatScrollPolicy.isNearBottom(
            offsetY: scrollView.contentOffset.y,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height,
            topInset: scrollView.adjustedContentInset.top,
            bottomInset: scrollView.adjustedContentInset.bottom
        )
    }

    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        // UIScrollView reports points/millisecond; the policy wants points/second.
        lastDragVelocityY = velocity.y * 1000
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        // VoiceOver (and any programmatic animated scroll) never sets
        // isDragging, so the didScroll guard skips it — recompute the follow
        // state from wherever the animation landed, or a VoiceOver user who
        // scrolled up to read gets yanked back to the bottom by the next
        // streaming delta.
        isFollowingBottom = ChatScrollPolicy.isNearBottom(
            offsetY: scrollView.contentOffset.y,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height,
            topInset: scrollView.adjustedContentInset.top,
            bottomInset: scrollView.adjustedContentInset.bottom
        )
        applyRangeStates()
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        applyRangeStates()
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            applyRangeStates()
        }
    }
}
#endif
