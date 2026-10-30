#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
import ChatMarkdownCore
import ChatTextLayout

/// SwiftUI wrapper for hosts that keep their own list/scrolling (the
/// performance-critical path is still the UIKit pipeline underneath).
///
/// Feed it the message's *full accumulated* Markdown on every update — the
/// coordinator diffs consecutive strings and ingests only the appended
/// suffix, so SwiftUI's "state is a whole value" model meets the streaming
/// pipeline without re-parsing the message per token. A non-append change
/// (regeneration, edit) tears down and replays from scratch.
///
/// Pass a shared `BlockLayoutScheduler` when rendering many messages so they
/// share one layout cache; by default all `StreamingMarkdownView`s in the
/// process share `ChatMarkdownSwiftUI.sharedScheduler`.
public struct StreamingMarkdownView: UIViewRepresentable {
    public let messageID: String
    public let markdown: String
    public let isComplete: Bool
    /// When true the view reports its *natural* content width (the widest laid-out
    /// block) instead of claiming the full proposed width — so a short message in
    /// a trailing bubble hugs its text instead of stretching edge-to-edge. The
    /// content still wraps at the proposed width, so hugging never reflows and
    /// the height is unchanged. Defaults to false (fill the width), matching the
    /// full-width assistant/answer layout.
    public var hugsContent: Bool
    public var scheduler: BlockLayoutScheduler?
    /// Which schemes a tapped link may carry to be opened. `.standard`
    /// (http/https/mailto) by default. Hosts that want custom app schemes
    /// tappable in message content (deep links, x-callback URLs) opt in with
    /// `.allow(…)` or `.anyExceptDangerous` — remember the markdown is
    /// untrusted, so a permissive policy means arbitrary content can invoke
    /// any installed app's URL handler when the user taps.
    public var linkSchemePolicy: SafeLinkPolicy.SchemePolicy
    public var onOpenLink: ((URL) -> Void)?

    public init(
        messageID: String,
        markdown: String,
        isComplete: Bool,
        hugsContent: Bool = false,
        scheduler: BlockLayoutScheduler? = nil,
        linkSchemePolicy: SafeLinkPolicy.SchemePolicy = .standard,
        onOpenLink: ((URL) -> Void)? = nil
    ) {
        self.messageID = messageID
        self.markdown = markdown
        self.isComplete = isComplete
        self.hugsContent = hugsContent
        self.scheduler = scheduler
        self.linkSchemePolicy = linkSchemePolicy
        self.onOpenLink = onOpenLink
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> MessageHostView {
        let host = MessageHostView()
        context.coordinator.configure(host: host)
        return host
    }

    public func updateUIView(_ host: MessageHostView, context: Context) {
        context.coordinator.apply(self, host: host)
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MessageHostView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let height = uiView.container.contentHeight
        // Hug the natural content width when asked (and known): the content
        // already wrapped at `width`, so `contentWidth ≤ width` and reporting it
        // shrinks the frame without reflowing. Fall back to the full width until
        // the first layout commits a natural width.
        if hugsContent {
            let natural = uiView.container.contentWidth
            if natural > 0 {
                return CGSize(width: min(width, ceil(natural)), height: height)
            }
        }
        return CGSize(width: width, height: height)
    }

    public static func dismantleUIView(_ uiView: MessageHostView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator {
        private var host: MessageHostView?
        private var renderer: MessageStreamRenderer?
        private var binding: MessageRenderBinding?
        private var scheduler: BlockLayoutScheduler?
        private var currentMessageID = ""
        private var ingested = ""
        private var finished = false
        /// Each restart is a new streaming lineage and MUST get a fresh
        /// internal MessageID: layout caches key on (messageID, birthOrder,
        /// revision), and a restarted assembler re-issues the same birth
        /// orders and revisions for *different* content. Reusing the ID made
        /// the shared scheduler serve the previous lineage's first-flush
        /// layout — messages visibly collapsed to their first few words.
        private var lineage: UInt64 = 0
        /// Serializes ingest/finish calls: unstructured Tasks are not FIFO,
        /// and out-of-order appends would corrupt the document.
        private var pipeline: Task<Void, Never>?
        private var onOpenLink: ((URL) -> Void)?
        private var linkSchemePolicy = SafeLinkPolicy.SchemePolicy.standard

        func configure(host: MessageHostView) {
            self.host = host
            host.container.onLinkActivate = { [weak self] rawDestination in
                guard let self,
                      let url = SafeLinkPolicy.validatedURL(
                          from: rawDestination,
                          policy: self.linkSchemePolicy
                      )
                else { return false }
                if let onOpenLink = self.onOpenLink {
                    onOpenLink(url)
                } else {
                    UIApplication.shared.open(url)
                }
                return true
            }
            host.container.onContentHeightChange = { [weak host] _ in
                host?.invalidateIntrinsicContentSize()
            }
            // Natural width changes (streaming growth, first layout) must also
            // re-query `sizeThatFits` so a hugging bubble tracks its content.
            host.container.onContentWidthChange = { [weak host] _ in
                host?.invalidateIntrinsicContentSize()
            }
            host.onWidthChange = { [weak self] width in
                guard let self, let renderer = self.renderer else { return }
                self.host?.container.updateWidth(width)
                self.enqueue { await renderer.updateEnvironment(width: width) }
            }
        }

        func apply(_ view: StreamingMarkdownView, host: MessageHostView) {
            onOpenLink = view.onOpenLink
            linkSchemePolicy = view.linkSchemePolicy
            let isAppend = view.messageID == currentMessageID
                && view.markdown.hasPrefix(ingested)
            if renderer == nil || !isAppend {
                restart(view, host: host)
                return
            }
            let suffix = String(view.markdown.dropFirst(ingested.count))
            ingested = view.markdown
            if !suffix.isEmpty, let renderer {
                enqueue { await renderer.ingest(suffix) }
            }
            if view.isComplete, !finished, let renderer {
                finished = true
                enqueue { await renderer.finishStream() }
            }
        }

        private func restart(_ view: StreamingMarkdownView, host: MessageHostView) {
            tearDown()
            currentMessageID = view.messageID
            ingested = view.markdown
            finished = false
            lineage &+= 1

            let width = host.bounds.width > 0 ? host.bounds.width : 320
            let scheduler = view.scheduler ?? ChatMarkdownSwiftUI.sharedScheduler
            self.scheduler = scheduler
            let renderer = MessageStreamRenderer(
                messageID: MessageID("\(view.messageID)#\(lineage)"),
                width: width,
                scheduler: scheduler
            )
            self.renderer = renderer
            host.container.reset()
            host.container.updateWidth(width)
            binding = MessageRenderBinding(renderer: renderer, container: host.container)

            let markdown = view.markdown
            let complete = view.isComplete
            if complete { finished = true }
            enqueue {
                if !markdown.isEmpty {
                    await renderer.ingest(markdown)
                    await renderer.flushNow()
                }
                if complete {
                    await renderer.finishStream()
                }
            }
        }

        private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
            let previous = pipeline
            pipeline = Task {
                await previous?.value
                await operation()
            }
        }

        func tearDown() {
            binding?.cancel()
            binding = nil
            pipeline?.cancel()
            pipeline = nil
            if let renderer {
                let retiredID = renderer.messageID
                let scheduler = scheduler
                Task {
                    await renderer.shutdown()
                    // Reclaim the retired lineage's cache entries — lineage
                    // IDs are unique, so nothing can reach them again.
                    await scheduler?.releaseMessage(retiredID)
                }
            }
            renderer = nil
        }
    }
}

/// Process-wide default scheduler for SwiftUI hosts: every message rendered
/// through `StreamingMarkdownView` shares one layout cache and one staleness
/// authority, matching what `ChatConversationViewController` does for UIKit
/// hosts.
@MainActor
public enum ChatMarkdownSwiftUI {
    public static let sharedScheduler = BlockLayoutScheduler()
}

/// The representable's UIKit view: hosts one `MessageBlockContainerView`,
/// reports width changes upward, and exposes the container's stacked height
/// as its intrinsic size so SwiftUI tracks streaming growth.
public final class MessageHostView: UIView {
    public let container = MessageBlockContainerView(frame: .zero)
    var onWidthChange: ((CGFloat) -> Void)?
    private var lastWidthBucket = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MessageHostView does not support NSCoder")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        container.frame = bounds
        let bucket = RenderCacheKey.widthBucket(for: bounds.width)
        if bounds.width > 0, bucket != lastWidthBucket {
            lastWidthBucket = bucket
            onWidthChange?(bounds.width)
        }
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: container.contentHeight)
    }
}
#endif
