import CoreGraphics
import Foundation
import ChatMarkdownCore

/// Owns background layout for non-code blocks: schedules work off-main,
/// caches immutable results, cancels superseded work, and refuses to commit
/// stale results.
///
/// Staleness rule: every request records `latestKey[blockID]`. A finished
/// layout commits only if its key is still the latest for that block —
/// a newer revision, width, or environment silently wins.
///
/// Delivery is multicast: any number of subscribers (typically one message
/// renderer per message, sharing this scheduler and its cache) receive
/// commits through their own stream. Streams don't replay — subscribe before
/// requesting, or re-request through `layoutAll` (cache hits re-emit
/// instantly).
public actor BlockLayoutScheduler {
    public struct Commit: Sendable {
        public let key: RenderCacheKey
        public let result: BlockLayoutResult
        public let fromCache: Bool
    }

    private struct Subscriber {
        let messageFilter: MessageID?
        let continuation: AsyncStream<Commit>.Continuation
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private let cache: LRUCache<RenderCacheKey, BlockLayoutResult>
    private var latestKey: [BlockID: RenderCacheKey] = [:]
    private var inFlight: [BlockID: Task<Void, Never>] = [:]

    // Test/telemetry instrumentation.
    private(set) var computeCount = 0
    private(set) var droppedStaleCount = 0
    var subscriberCount: Int { subscribers.count }

    public init(cacheCostBudget: Int = 2_000_000) {
        cache = LRUCache(costLimit: cacheCostBudget)
    }

    /// A live stream of commits, optionally filtered to one message.
    /// Each call returns an independent stream (safe for cell reuse).
    public func commits(for messageID: MessageID? = nil) -> AsyncStream<Commit> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Commit.self)
        subscribers[id] = Subscriber(messageFilter: messageID, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// Schedules layout for exactly the blocks a delta touched. Removed blocks
    /// have their in-flight work cancelled.
    public func process(
        _ delta: DocumentDelta,
        width: CGFloat,
        theme: TextTheme,
        environment: RenderEnvironment,
        priority: TaskPriority = .userInitiated
    ) {
        for id in delta.removedBlockIDs { release(id) }
        let dirty = Set(delta.insertedBlockIDs).union(delta.updatedBlockIDs)
        guard !dirty.isEmpty else { return }
        for block in delta.document.blocks where dirty.contains(block.id) {
            requestLayout(for: block, width: width, theme: theme, environment: environment, priority: priority)
        }
    }

    /// Schedules layout for every block of a document — used when a new
    /// subscriber attaches to an existing message (cache hits replay
    /// immediately) or after an environment change.
    public func layoutAll(
        _ document: MarkdownDocument,
        width: CGFloat,
        theme: TextTheme,
        environment: RenderEnvironment,
        priority: TaskPriority = .userInitiated
    ) {
        for block in document.blocks {
            requestLayout(for: block, width: width, theme: theme, environment: environment, priority: priority)
        }
    }

    public func requestLayout(
        for block: MarkdownBlock,
        width: CGFloat,
        theme: TextTheme,
        environment: RenderEnvironment,
        priority: TaskPriority = .userInitiated
    ) {
        // Top-level code blocks belong to the code subsystem (line-oriented,
        // viewport-driven); laying them out as one rich-text mass is exactly
        // the failure mode this library exists to avoid.
        guard block.content.kind != .codeBlock else { return }

        let key = RenderCacheKey(
            blockID: block.id,
            blockRevision: block.revision,
            width: width,
            environment: environment
        )
        if latestKey[block.id] == key {
            if inFlight[block.id] != nil {
                return // identical request already running
            }
            if let cached = cache.value(for: key) {
                RenderSignposts.layout.emitEvent("cache.hit")
                broadcast(Commit(key: key, result: cached, fromCache: true))
                return
            }
        }
        latestKey[block.id] = key
        inFlight[block.id]?.cancel()
        inFlight[block.id] = nil

        if let cached = cache.value(for: key) {
            RenderSignposts.layout.emitEvent("cache.hit")
            broadcast(Commit(key: key, result: cached, fromCache: true))
            return
        }

        computeCount += 1
        RenderSignposts.layout.emitEvent("cache.miss")
        let task = Task.detached(priority: priority) { [weak self] in
            // Pure CPU work off the actor; commit hops back for the gate.
            let result = RenderSignposts.layout.withIntervalSignpost("prose.layout") {
                BlockLayoutEngine.layout(
                    block: block, width: width, theme: theme, environment: environment
                )
            }
            guard !Task.isCancelled else { return }
            await self?.commit(result, key: key)
        }
        inFlight[block.id] = task
    }

    /// Internal so tests can drive the staleness gate deterministically.
    func commit(_ result: BlockLayoutResult, key: RenderCacheKey) {
        guard latestKey[key.blockID] == key else {
            droppedStaleCount += 1
            RenderSignposts.layout.emitEvent("commit.staleDropped")
            return
        }
        inFlight[key.blockID] = nil
        cache.insert(result, for: key, cost: result.estimatedCost)
        broadcast(Commit(key: key, result: result, fromCache: false))
    }

    public func cachedResult(for key: RenderCacheKey) -> BlockLayoutResult? {
        cache.value(for: key)
    }

    /// Exact content height of a message without any cell: lays out cache
    /// misses inline (on this actor, off-main) and inserts them, so the
    /// eventual cell bind replays from cache. Code blocks are sized by line
    /// count alone — no code layout ever happens here.
    ///
    /// Uses the same `MessageStacking` math as `MessageBlockContainerView`,
    /// so measured heights equal rendered heights and list geometry never
    /// jumps when a cell appears.
    public func measuredContentHeight(
        of document: MarkdownDocument,
        width: CGFloat,
        theme: TextTheme,
        environment: RenderEnvironment,
        metrics: MessageLayoutMetrics
    ) -> CGFloat {
        RenderSignposts.layout.withIntervalSignpost("height.measure") {
            let codeLineHeight = metrics.codeLineHeight
            var y: CGFloat = 0
            for (index, block) in document.blocks.enumerated() {
                if index > 0 { y += metrics.blockSpacing }
                if case .codeBlock(let code) = block.content {
                    y += MessageStacking.codeBlockHeight(
                        lineCount: MessageStacking.codeLineCount(forRawText: code.rawText),
                        lineHeight: codeLineHeight,
                        metrics: metrics
                    )
                    continue
                }
                let key = RenderCacheKey(
                    blockID: block.id,
                    blockRevision: block.revision,
                    width: width,
                    environment: environment
                )
                if let cached = cache.value(for: key) {
                    y += cached.size.height
                } else {
                    let result = BlockLayoutEngine.layout(
                        block: block, width: width, theme: theme, environment: environment
                    )
                    computeCount += 1
                    cache.insert(result, for: key, cost: result.estimatedCost)
                    y += result.size.height
                }
            }
            return max(0, y)
        }
    }

    /// Batch release for the retained-window policy.
    public func releaseMessages(_ messageIDs: [MessageID]) {
        for id in messageIDs {
            releaseMessage(id)
        }
    }

    /// Drops all cached layout and cancels all work. Callers re-request via
    /// `layoutAll` with the new environment.
    public func invalidateAllLayouts() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        latestKey.removeAll()
        cache.removeAll()
    }

    /// Releases per-message state when a message leaves the retained window.
    /// Layout is recomputable from the document, so this is always safe.
    public func releaseMessage(_ messageID: MessageID) {
        for (id, task) in inFlight where id.messageID == messageID {
            task.cancel()
            inFlight[id] = nil
        }
        latestKey = latestKey.filter { $0.key.messageID != messageID }
        cache.removeAll { $0.blockID.messageID == messageID }
        // Reclaim commit streams filtered to this message, so window-release
        // also releases forwarding tasks parked in `for await`. Renderers
        // re-register on their next subscribe/flush.
        for (id, subscriber) in subscribers where subscriber.messageFilter == messageID {
            subscriber.continuation.finish()
            subscribers[id] = nil
        }
    }

    public func shutdown() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        for subscriber in subscribers.values { subscriber.continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: - Internals

    private func broadcast(_ commit: Commit) {
        for subscriber in subscribers.values {
            if let filter = subscriber.messageFilter, filter != commit.key.blockID.messageID {
                continue
            }
            subscriber.continuation.yield(commit)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func release(_ id: BlockID) {
        inFlight[id]?.cancel()
        inFlight[id] = nil
        latestKey[id] = nil
    }
}
