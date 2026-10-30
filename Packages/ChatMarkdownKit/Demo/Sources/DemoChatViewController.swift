import UIKit
import ChatMarkdownCore
import ChatTextLayout
import ChatMarkdownUI

/// Hosts a `ChatConversationViewController` as a child and runs a scripted
/// conversation through the streaming pipeline.
///
/// Built for hands-on (and VoiceOver-driven) testing:
/// - A **Pace** button cycles slow / normal / fast. Slow stretches the whole
///   stream ~4×, leaving time to focus targets — a large code block is its
///   own scrollable element, which takes a moment to reach and explore.
/// - A **Replay** button restarts the conversation without relaunching.
/// - The script is long (an essay and a mixed code/prose walkthrough follow
///   the 10,000-line dump), so there is always live streaming to interact
///   with.
final class DemoChatViewController: UIViewController {
    private enum Pace: CaseIterable {
        case slow, normal, fast

        var multiplier: Double {
            switch self {
            case .slow: return 4
            case .normal: return 1
            case .fast: return 0.25
            }
        }

        var title: String {
            switch self {
            case .slow: return "Pace: Slow"
            case .normal: return "Pace: Normal"
            case .fast: return "Pace: Fast"
            }
        }

        var announcement: String {
            switch self {
            case .slow: return "Streaming pace slow"
            case .normal: return "Streaming pace normal"
            case .fast: return "Streaming pace fast"
            }
        }

        var next: Pace {
            let all = Pace.allCases
            let index = all.firstIndex(of: self)!
            return all[(index + 1) % all.count]
        }
    }

    private let scheduler = BlockLayoutScheduler()
    private var conversation: ChatConversationViewController?
    private var scriptTask: Task<Void, Never>?
    private var runIndex = 0
    private var pace: Pace = .normal
    private var paceButton: UIBarButtonItem!

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DemoChatViewController does not support NSCoder")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        paceButton = UIBarButtonItem(
            title: pace.title,
            style: .plain,
            target: self,
            action: #selector(cyclePace)
        )
        paceButton.accessibilityHint = "Cycles the streaming speed between slow, normal, and fast."
        let replayButton = UIBarButtonItem(
            title: "Replay",
            style: .plain,
            target: self,
            action: #selector(replay)
        )
        replayButton.accessibilityHint = "Restarts the scripted conversation from the beginning."
        navigationItem.rightBarButtonItem = paceButton
        navigationItem.leftBarButtonItem = replayButton

        installConversation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard scriptTask == nil else { return }
        startScript()
    }

    // MARK: - Controls

    @objc private func cyclePace() {
        pace = pace.next
        paceButton.title = pace.title
        UIAccessibility.post(notification: .announcement, argument: pace.announcement)
    }

    @objc private func replay() {
        scriptTask?.cancel()
        scriptTask = nil
        runIndex += 1
        installConversation()
        UIAccessibility.post(notification: .screenChanged, argument: "Conversation restarted")
        startScript()
    }

    private func installConversation() {
        if let old = conversation {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        let fresh = ChatConversationViewController(scheduler: scheduler)
        addChild(fresh)
        fresh.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fresh.view)
        NSLayoutConstraint.activate([
            fresh.view.topAnchor.constraint(equalTo: view.topAnchor),
            fresh.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fresh.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fresh.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        fresh.didMove(toParent: self)
        fresh.onOpenLink = { [weak self] url in
            let alert = UIAlertController(
                title: "Link",
                message: url.absoluteString,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        }
        conversation = fresh
    }

    private func startScript() {
        let run = runIndex
        scriptTask = Task { await self.runScript(run: run) }
    }

    /// Sleeps a base duration scaled by the current pace; re-reads the pace
    /// every call so mid-stream changes take effect immediately.
    private func paceSleep(baseMilliseconds: Int) async {
        let scaled = Int(Double(baseMilliseconds) * pace.multiplier)
        try? await Task.sleep(for: .milliseconds(max(1, scaled)))
    }

    // MARK: - Scripted conversation

    private func runScript(run: Int) async {
        // Chunking the long scripts is O(text) Substring iteration — a device
        // trace caught it blocking a frame when done at message kickoff on
        // the main actor. Precompute everything off-main before streaming.
        let prepared = await Task.detached(priority: .userInitiated) {
            PreparedChunks(
                rich: Self.wordChunks(from: Self.richAnswerMarkdown, wordsPerChunk: 5),
                essay: Self.wordChunks(from: Self.essayMarkdown(), wordsPerChunk: 4),
                mixed: Self.wordChunks(from: Self.mixedCodeMarkdown, wordsPerChunk: 5),
                closing: Self.wordChunks(
                    from: "That's the whole tour. Everything you scrolled past stays cheap: cold messages release their layout caches and rewarm before they return. Replay any time.",
                    wordsPerChunk: 1
                )
            )
        }.value

        await streamMarkdown(
            id: "user-1-r\(run)",
            chunks: [
                "Hey! What kinds of Markdown ",
                "can this renderer handle ",
                "while a reply is still streaming?",
            ],
            baseDelayMs: 30
        )
        await streamMarkdown(id: "assistant-1-r\(run)", chunks: prepared.rich, baseDelayMs: 20)
        await streamMarkdown(
            id: "user-2-r\(run)",
            chunks: ["Nice. Now show me how it ", "holds up against a really ", "huge code block."],
            baseDelayMs: 30
        )
        await streamAssemblyDump(id: "assistant-2-r\(run)")
        await streamMarkdown(
            id: "user-3-r\(run)",
            chunks: ["Good. Now something long-form — ", "give me prose I can actually ", "read through while it streams."],
            baseDelayMs: 30
        )
        await streamMarkdown(id: "assistant-3-r\(run)", chunks: prepared.essay, baseDelayMs: 25)
        await streamMarkdown(
            id: "user-4-r\(run)",
            chunks: ["Last one: mix code and prose ", "in a single answer."],
            baseDelayMs: 30
        )
        await streamMarkdown(id: "assistant-4-r\(run)", chunks: prepared.mixed, baseDelayMs: 22)
        await streamMarkdown(id: "assistant-5-r\(run)", chunks: prepared.closing, baseDelayMs: 30)
    }

    private struct PreparedChunks: Sendable {
        let rich: [String]
        let essay: [String]
        let mixed: [String]
        let closing: [String]
    }

    /// Creates a renderer on the shared scheduler, appends it to the
    /// conversation *before* streaming, then feeds it the chunks.
    private func appendRenderer(id: String) -> MessageStreamRenderer? {
        guard let conversation else { return nil }
        let renderer = MessageStreamRenderer(
            messageID: MessageID(id),
            width: max(320, view.bounds.width - 24),
            sender: id.hasPrefix("user") ? .user : .assistant,
            scheduler: scheduler
        )
        conversation.append(renderer)
        return renderer
    }

    private func streamMarkdown(id: String, chunks: [String], baseDelayMs: Int) async {
        guard !Task.isCancelled, let renderer = appendRenderer(id: id) else { return }
        for chunk in chunks {
            if Task.isCancelled { return }
            await renderer.ingest(chunk)
            await paceSleep(baseMilliseconds: baseDelayMs)
        }
        await renderer.finishStream()
    }

    /// Streams a fenced code block containing a generated 10,000-line
    /// assembly-style dump, in chunks of ~40 lines.
    private func streamAssemblyDump(id: String) async {
        guard !Task.isCancelled, let renderer = appendRenderer(id: id) else { return }
        await renderer.ingest("Here comes a 10,000-line disassembly dump:\n\n```asm\n")

        let mnemonics = [
            "mov", "ldr", "str", "add", "sub", "cmp", "b.ne", "bl",
            "stp", "ldp", "orr", "and", "lsl", "lsr", "cbz", "ret",
        ]
        let totalLines = 10_000
        let linesPerChunk = 40
        var line = 0
        while line < totalLines {
            if Task.isCancelled { return }
            var chunk = ""
            let upper = min(line + linesPerChunk, totalLines)
            while line < upper {
                let address = 0x1000_3F00 + line * 4
                let word = UInt32(truncatingIfNeeded: address &* 2654435761)
                let mnemonic = mnemonics[line % mnemonics.count]
                chunk += String(
                    format: "%08x:  %08x    %@ x%d, x%d, #0x%x\n",
                    address, word, mnemonic, line % 31, (line * 7) % 31, (line * 13) % 4096
                )
                line += 1
            }
            await renderer.ingest(chunk)
            await paceSleep(baseMilliseconds: 10)
        }
        await renderer.ingest("```\n\nAll 10,000 lines landed without dropping a frame.")
        await renderer.finishStream()
    }

    // MARK: - Content

    /// Splits Markdown into small streaming chunks (a few words each) while
    /// preserving newlines, so blocks arrive as partial lines.
    nonisolated private static func wordChunks(from markdown: String, wordsPerChunk: Int) -> [String] {
        var chunks: [String] = []
        for lineSub in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let words = lineSub.split(separator: " ", omittingEmptySubsequences: false)
            var index = 0
            while index < words.count {
                let upper = min(index + wordsPerChunk, words.count)
                var piece = words[index..<upper].joined(separator: " ")
                if upper < words.count { piece += " " }
                index = upper
                if upper == words.count { piece += "\n" }
                chunks.append(piece)
            }
            if words.isEmpty {
                chunks.append("\n")
            }
        }
        return chunks
    }

    /// A deterministic multi-section essay (~1,300 words): headings, lists,
    /// quotes, and paragraph after paragraph of readable prose — enough
    /// runway to navigate by heading, read paragraphs, and follow links
    /// while the stream is still arriving further down.
    nonisolated private static func essayMarkdown() -> String {
        let sections: [(title: String, lead: String)] = [
            ("Why streaming rendering is different", "A chat renderer never sees a finished document. It sees a document becoming."),
            ("Identity is the quiet foundation", "Nothing else works unless a block can keep its name while it grows."),
            ("The main thread is a budget", "Every millisecond spent on the main thread is borrowed from scrolling."),
            ("Code blocks are their own world", "Ten thousand lines is not rich text; it is a data structure."),
            ("Accessibility is the same model, spoken", "If the semantic model is honest, VoiceOver gets honesty for free."),
            ("Measurement beats intuition", "Traces on real hardware settle arguments that architecture diagrams start."),
        ]
        let bodies = [
            "The pipeline treats every token as a promise that more is coming. Parses stay incremental, layout stays block-scoped, and nothing downstream is allowed to assume completion. That single discipline is what keeps a fast stream from feeling like a slideshow of reflows.",
            "When a paragraph grows, its neighbors do not move except by simple stacking. The scroll position anchors to what you are reading, not to whatever happens to be arriving. Growth below your viewport is free; corrections above it are compensated to the pixel.",
            "Each block carries a stable identity from the moment it is born. Caches key on that identity plus a revision, so an unchanged block never pays for its neighbor's churn. This is also why the accessibility tree stays calm: elements persist, labels update in place, and focus has somewhere to live.",
            "There is a strict split between deciding what to draw and drawing it. Deciding happens off the main thread, against immutable snapshots, with stale results discarded at a gate. Drawing is the cheap part — replaying a finished plan into pixels.",
        ]
        var markdown = "# A short essay on streaming text\n\n"
        markdown += "This answer exists to give you time. It keeps arriving, section after section, so you can navigate by heading, read a paragraph, or park focus on the dump above and come back — the stream will still be here.\n\n"
        for (index, section) in sections.enumerated() {
            markdown += "## \(section.title)\n\n"
            markdown += "\(section.lead) \(bodies[index % bodies.count])\n\n"
            markdown += "\(bodies[(index + 1) % bodies.count])\n\n"
            if index == 1 {
                markdown += "Three invariants hold the whole time:\n\n"
                markdown += "1. An unchanged block is never re-laid-out\n"
                markdown += "2. A stale result is never committed\n"
                markdown += "3. Measured height always equals rendered height\n\n"
            }
            if index == 3 {
                markdown += "> A code block that virtualizes its lines can afford to be enormous. One that does not can barely afford to exist.\n\n"
            }
        }
        markdown += "If you want the deeper version, the [architecture notes](https://example.com/architecture) cover every layer of this pipeline.\n"
        return markdown
    }

    nonisolated private static let mixedCodeMarkdown = """
    # Mixing prose and code

    Real answers interleave explanation with runnable pieces. Here the \
    renderer alternates prose paragraphs with fenced blocks — each block is \
    its own scrollable, copyable element with a spoken line count.

    First, a small model type:

    ```swift
    struct Message: Identifiable, Sendable {
        let id: MessageID
        var blocks: [MarkdownBlock]
        var isComplete: Bool
    }
    ```

    The renderer consumes tokens through a coalescing façade, so a hundred \
    tokens a second cost about twenty parses:

    ```swift
    let renderer = MessageStreamRenderer(
        messageID: MessageID("reply-42"),
        width: 360,
        scheduler: sharedScheduler
    )
    for await token in modelStream {
        await renderer.ingest(token)
    }
    await renderer.finishStream()
    ```

    Heights come from the same math everywhere, which is the entire trick \
    behind jump-free scrolling:

    | Consumer | Source |
    | --- | --- |
    | List geometry | measuredContentHeight |
    | Cell container | MessageStacking |
    | Code blocks | line count × line height |

    And finally, the part everyone copies into their own project:

    ```swift
    conversation.onOpenLink = { url in
        // SafeLinkPolicy has already validated the scheme.
        UIApplication.shared.open(url)
    }
    ```

    Every one of those blocks arrived while the list was live. None of them \
    ever laid out on the main thread.
    """

    nonisolated private static let richAnswerMarkdown = """
    # Markdown, streamed live

    Everything you see here arrived **token by token** and was parsed \
    *incrementally* — no re-render of the whole message, just the blocks \
    that changed. Inline styles like `let x = 42` are laid out off the \
    main thread with CoreText.

    Full details live in the [documentation](https://example.com/docs), \
    which covers the streaming assembler and layout scheduler.

    Things it handles mid-stream:

    - Paragraphs with **bold**, *italic*, and `inline code`
    - Links that pass a safe-link policy before opening
    - Lists that grow while tokens arrive

    And the pipeline, in order:

    1. Tokens are coalesced into ~48 ms flushes
    2. The assembler diffs the block list
    3. The scheduler lays out only dirty blocks

    > Layout is computed off-main and committed back with a stale-commit \
    > gate, so fast streams never paint out-of-order text.

    | Feature | Engine | Thread |
    | --- | --- | --- |
    | Rich text | CoreText lines | Background |
    | Code blocks | Line-oriented | Background |
    | Heights | Shared LRU cache | Background |

    Here is a realistic Swift excerpt, streamed as a fenced block:

    ```swift
    import Foundation

    /// A tiny token-bucket rate limiter used by the demo backend.
    actor RateLimiter {
        private let capacity: Double
        private let refillPerSecond: Double
        private var tokens: Double
        private var lastRefill: ContinuousClock.Instant

        init(capacity: Double, refillPerSecond: Double) {
            self.capacity = capacity
            self.refillPerSecond = refillPerSecond
            self.tokens = capacity
            self.lastRefill = .now
        }

        func acquire(cost: Double = 1) async {
            while true {
                refill()
                if tokens >= cost {
                    tokens -= cost
                    return
                }
                let deficit = cost - tokens
                let wait = deficit / refillPerSecond
                try? await Task.sleep(for: .seconds(wait))
            }
        }

        private func refill() {
            let now = ContinuousClock.Instant.now
            let elapsed = lastRefill.duration(to: now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            tokens = min(capacity, tokens + seconds * refillPerSecond)
            lastRefill = now
        }
    }

    let limiter = RateLimiter(capacity: 10, refillPerSecond: 2)
    await limiter.acquire()
    print("request admitted")
    ```

    Scroll up while it streams — the list anchor-compensates instead of \
    yanking you back down.
    """
}
