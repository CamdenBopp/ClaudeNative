import CoreGraphics
import Foundation
import ChatMarkdownCore

/// Per-message façade tying the pipeline together: token ingestion with
/// coalescing → assembler (parse + identity) → layout scheduler → multicast
/// event streams the UI consumes.
///
/// Coalescing: individual tokens are buffered and flushed on a short interval,
/// so a 100-token/second stream costs ~20 parses/second, not 100. The interval
/// is a latency ceiling, not a delay floor.
///
/// Subscription: `subscribe()` returns an independent stream that begins with
/// a catch-up snapshot (the full current document as one delta, followed by
/// cached layout commits), then live updates. This is what makes cell reuse
/// safe — a rebinding cell simply subscribes again and is brought current.
///
/// IDENTITY CONTRACT: a `MessageID` names one streaming *lineage*. Never
/// create a second renderer with the same ID on the same scheduler — layout
/// caches key on (messageID, birthOrder, revision), and a fresh assembler
/// re-issues the same birth orders and revisions for different content, so
/// the shared cache would serve the earlier lineage's layouts. Restart flows
/// must mint a new ID (e.g. suffix a generation counter) and release the
/// retired one via `BlockLayoutScheduler.releaseMessage`.
public actor MessageStreamRenderer {
    public enum Event: Sendable {
        case document(DocumentDelta)
        case layout(BlockLayoutScheduler.Commit)
    }

    public nonisolated let messageID: MessageID
    /// Who authored this message — presentation metadata the conversation view
    /// uses to pick a bubble appearance and its matching geometry. Never
    /// consulted by layout, which is sender-agnostic.
    public nonisolated let sender: MessageSender

    private let assembler: StreamingMessageAssembler
    private let scheduler: BlockLayoutScheduler
    private var width: CGFloat
    private var theme: TextTheme
    private var environment: RenderEnvironment
    private let coalesceInterval: Duration

    private var pending = ""
    private var flushScheduled = false
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var forwardTask: Task<Void, Never>?
    private var forwardingStarted = false

    /// - Parameter scheduler: pass a shared scheduler so all messages in a
    ///   conversation share one layout cache and one staleness authority.
    public init(
        messageID: MessageID,
        width: CGFloat,
        sender: MessageSender = .assistant,
        theme: TextTheme = .default,
        environment: RenderEnvironment = RenderEnvironment(),
        coalesceInterval: Duration = .milliseconds(48),
        scheduler: BlockLayoutScheduler = BlockLayoutScheduler()
    ) {
        self.messageID = messageID
        self.sender = sender
        self.assembler = StreamingMessageAssembler(messageID: messageID)
        self.scheduler = scheduler
        self.width = width
        self.theme = theme
        self.environment = environment
        self.coalesceInterval = coalesceInterval
    }

    deinit {
        // Without this, a discarded renderer leaks its forwarding task: the
        // task sits suspended in `for await` (holding self only weakly) and
        // the scheduler keeps the matching subscriber continuation forever.
        // Cancelling here tears the whole chain down: the stream iterator's
        // cancellation fires `onTermination`, which removes the scheduler-side
        // subscriber.
        forwardTask?.cancel()
    }

    /// Registers the commit-forwarding subscription with the scheduler. Runs
    /// lazily before the first flush/subscribe so registration is guaranteed
    /// to precede any layout request this renderer issues — commits can't
    /// slip through unobserved. The flag is set before the suspension point
    /// so reentrant callers can't double-subscribe.
    private func ensureForwarding() async {
        guard !forwardingStarted else { return }
        forwardingStarted = true
        let commits = await scheduler.commits(for: messageID)
        // Self is held weakly per event so the renderer can deinit while the
        // shared scheduler lives on.
        forwardTask = Task { [weak self] in
            for await commit in commits {
                guard let self else { return }
                await self.broadcast(.layout(commit))
            }
            // The scheduler finished this stream (e.g. retained-window
            // release). Allow a later subscribe/flush to re-register, so a
            // released message that scrolls back into view forwards commits
            // again. Skip on cancellation: shutdown()/deinit own teardown.
            guard !Task.isCancelled else { return }
            await self?.forwardingDidEnd()
        }
    }

    private func forwardingDidEnd() {
        forwardingStarted = false
        forwardTask = nil
    }

    /// Test hook: whether a scheduler-side commit subscription is currently
    /// registered.
    var isForwardingRegistered: Bool { forwardingStarted }

    // MARK: - Subscription

    /// An independent event stream: catch-up snapshot first, then live
    /// updates. Safe to call repeatedly (each cell binding gets its own).
    public func subscribe() async -> AsyncStream<Event> {
        await ensureForwarding()
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }

        let document = assembler.currentDocument
        // Completed-but-empty documents must also replay: a subscriber that
        // just missed the final broadcast of an empty document would otherwise
        // never learn the stream is complete and would wait forever.
        if !document.blocks.isEmpty || document.isComplete {
            // Snapshot: everything presented as inserted, so a fresh container
            // builds the full view hierarchy...
            continuation.yield(.document(DocumentDelta(
                document: document,
                insertedBlockIDs: document.blocks.map(\.id),
                updatedBlockIDs: [],
                removedBlockIDs: []
            )))
            // ...and cached layouts replay through the commit stream.
            await scheduler.layoutAll(document, width: width, theme: theme, environment: environment)
        }
        return stream
    }

    // MARK: - Streaming input

    public func ingest(_ chunk: String) {
        pending += chunk
        guard !flushScheduled else { return }
        flushScheduled = true
        let interval = coalesceInterval
        Task { [weak self] in
            try? await Task.sleep(for: interval)
            await self?.scheduledFlush()
        }
    }

    public func finishStream() async {
        await ensureForwarding()
        await flushPending()
        let delta = assembler.finish()
        broadcast(.document(delta))
        await scheduler.process(delta, width: width, theme: theme, environment: environment)
    }

    /// Immediate flush — for tests and for hosts that want to force a paint
    /// (e.g. right before the message scrolls on screen).
    public func flushNow() async {
        await flushPending()
    }

    // MARK: - Environment

    /// Re-lays-out the whole message under new geometry/appearance inputs.
    /// Old cache entries die by LRU aging (their keys no longer match), so no
    /// global invalidation is needed and other messages are unaffected.
    /// Update the container's width first — it gates commits by width bucket.
    public func updateEnvironment(
        width: CGFloat? = nil,
        theme: TextTheme? = nil,
        environment: RenderEnvironment? = nil
    ) async {
        if let width { self.width = width }
        if let theme { self.theme = theme }
        if let environment { self.environment = environment }
        await ensureForwarding()
        await scheduler.layoutAll(
            assembler.currentDocument,
            width: self.width, theme: self.theme, environment: self.environment
        )
    }

    public func currentDocument() -> MarkdownDocument {
        assembler.currentDocument
    }

    /// Stops commit forwarding and closes all subscriber streams. Does not
    /// shut down the scheduler, which may be shared across messages.
    public func shutdown() {
        forwardTask?.cancel()
        forwardTask = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: - Internals

    private func broadcast(_ event: Event) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func scheduledFlush() async {
        flushScheduled = false
        await flushPending()
    }

    private func flushPending() async {
        guard !pending.isEmpty else { return }
        await ensureForwarding()
        let chunk = pending
        pending = ""
        let delta = RenderSignposts.streaming.withIntervalSignpost("stream.flush") {
            assembler.append(chunk)
        }
        broadcast(.document(delta))
        await scheduler.process(delta, width: width, theme: theme, environment: environment)
    }
}
