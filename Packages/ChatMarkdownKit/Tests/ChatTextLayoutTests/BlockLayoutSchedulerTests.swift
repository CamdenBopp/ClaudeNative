import CoreGraphics
import Foundation
import Testing
import ChatMarkdownCore
@testable import ChatTextLayout

private let environment = RenderEnvironment()

private func makeBlock(
    _ content: BlockContent,
    birthOrder: Int = 0,
    revision: BlockRevision = .zero,
    message: String = "sched-test"
) -> MarkdownBlock {
    MarkdownBlock(
        id: BlockID(messageID: MessageID(message), birthOrder: birthOrder),
        revision: revision,
        content: content
    )
}

struct BlockLayoutSchedulerTests {
    @Test func commitIsDeliveredToSubscribers() async throws {
        let scheduler = BlockLayoutScheduler()
        let block = makeBlock(.paragraph(.plain("Hello scheduler")))
        var iterator = await scheduler.commits().makeAsyncIterator()

        await scheduler.requestLayout(for: block, width: 300, theme: .default, environment: environment)
        let commit = await iterator.next()
        try #require(commit != nil)
        #expect((commit?.result.size.height ?? 0) > 0)
        #expect(commit?.fromCache == false)
        #expect(commit?.key.blockID == block.id)
    }

    @Test func messageFilteredStreamOnlySeesItsMessage() async throws {
        let scheduler = BlockLayoutScheduler()
        let mine = makeBlock(.paragraph(.plain("mine")), message: "msg-a")
        let other = makeBlock(.paragraph(.plain("other")), message: "msg-b")
        var iterator = await scheduler.commits(for: MessageID("msg-a")).makeAsyncIterator()

        await scheduler.requestLayout(for: other, width: 300, theme: .default, environment: environment)
        await scheduler.requestLayout(for: mine, width: 300, theme: .default, environment: environment)

        let commit = await iterator.next()
        #expect(commit?.key.blockID.messageID == MessageID("msg-a"))
    }

    @Test func secondIdenticalRequestIsServedFromCache() async throws {
        let scheduler = BlockLayoutScheduler()
        let block = makeBlock(.paragraph(.plain("Cache me")))
        var iterator = await scheduler.commits().makeAsyncIterator()

        await scheduler.requestLayout(for: block, width: 300, theme: .default, environment: environment)
        let first = await iterator.next()
        #expect(first?.fromCache == false)

        await scheduler.requestLayout(for: block, width: 300, theme: .default, environment: environment)
        let second = await iterator.next()
        #expect(second?.fromCache == true)
        let computeCount = await scheduler.computeCount
        #expect(computeCount == 1)
    }

    @Test func widthChangeRecomputes() async throws {
        let scheduler = BlockLayoutScheduler()
        let block = makeBlock(.paragraph(.plain("Width sensitive text that wraps differently at different widths")))
        var iterator = await scheduler.commits().makeAsyncIterator()

        await scheduler.requestLayout(for: block, width: 300, theme: .default, environment: environment)
        _ = await iterator.next()
        await scheduler.requestLayout(for: block, width: 150, theme: .default, environment: environment)
        let second = await iterator.next()
        #expect(second?.fromCache == false)
        let computeCount = await scheduler.computeCount
        #expect(computeCount == 2)
    }

    @Test func staleCommitIsDropped() async throws {
        let scheduler = BlockLayoutScheduler()
        let id = BlockID(messageID: MessageID("stale"), birthOrder: 0)
        let rev0 = MarkdownBlock(id: id, revision: .zero, content: .paragraph(.plain("old")))
        let rev1 = MarkdownBlock(id: id, revision: BlockRevision(1), content: .paragraph(.plain("new")))

        var iterator = await scheduler.commits().makeAsyncIterator()
        await scheduler.requestLayout(for: rev1, width: 300, theme: .default, environment: environment)
        let commit = await iterator.next()
        #expect(commit?.key.blockRevision == BlockRevision(1))

        // Simulate a slow rev0 layout finishing after rev1 became current.
        let staleKey = RenderCacheKey(blockID: id, blockRevision: .zero, width: 300, environment: environment)
        let staleResult = BlockLayoutEngine.layout(block: rev0, width: 300, theme: .default, environment: environment)
        await scheduler.commit(staleResult, key: staleKey)

        let dropped = await scheduler.droppedStaleCount
        #expect(dropped == 1)
        let cached = await scheduler.cachedResult(for: staleKey)
        #expect(cached == nil)
    }

    @Test func codeBlocksAreNotScheduled() async {
        let scheduler = BlockLayoutScheduler()
        let block = makeBlock(.codeBlock(CodeBlockContent(languageHint: "swift", rawText: "let x = 1\n", isClosed: true)))
        await scheduler.requestLayout(for: block, width: 300, theme: .default, environment: environment)
        let computeCount = await scheduler.computeCount
        #expect(computeCount == 0)
    }

    @Test func releaseMessageDropsCachedLayout() async throws {
        let scheduler = BlockLayoutScheduler()
        let block = makeBlock(.paragraph(.plain("Release me")), message: "released-msg")
        var iterator = await scheduler.commits().makeAsyncIterator()
        await scheduler.requestLayout(for: block, width: 300, theme: .default, environment: environment)
        let commit = await iterator.next()
        try #require(commit != nil)

        await scheduler.releaseMessage(MessageID("released-msg"))
        let cached = await scheduler.cachedResult(for: commit!.key)
        #expect(cached == nil)
    }

    @Test func processLaysOutOnlyDirtyBlocks() async throws {
        let scheduler = BlockLayoutScheduler()
        let assembler = StreamingMessageAssembler(messageID: MessageID("delta-msg"))
        assembler.append("First paragraph.\n\n")
        let delta = assembler.append("Second paragraph begins")
        try #require(delta.document.blocks.count == 2)

        var iterator = await scheduler.commits().makeAsyncIterator()
        await scheduler.process(delta, width: 300, theme: .default, environment: environment)
        // Only the new tail block is dirty; the first paragraph is untouched.
        let computeCount = await scheduler.computeCount
        #expect(computeCount == 1)
        let commit = await iterator.next()
        #expect(commit?.key.blockID == delta.document.blocks[1].id)
    }
}

struct MessageStreamRendererTests {
    @Test func senderDefaultsToAssistantAndIsSettable() {
        let defaulted = MessageStreamRenderer(messageID: MessageID("s1"), width: 320)
        #expect(defaulted.sender == .assistant)
        let user = MessageStreamRenderer(messageID: MessageID("s2"), width: 320, sender: .user)
        #expect(user.sender == .user)
    }

    @Test(.timeLimit(.minutes(1)))
    func streamedMessageProducesDocumentAndLayouts() async throws {
        let renderer = MessageStreamRenderer(
            messageID: MessageID("renderer-test"),
            width: 320,
            coalesceInterval: .milliseconds(2)
        )
        let chunks = ["# Ti", "tle\n\nBody ", "text with **bo", "ld** words.", " More prose."]
        for chunk in chunks {
            await renderer.ingest(chunk)
        }
        await renderer.finishStream()

        let document = await renderer.currentDocument()
        #expect(document.isComplete)
        try #require(document.blocks.count == 2)
        let expectedIDs = Set(document.blocks.map(\.id))

        // Late subscription: the snapshot + layout replay must bring us
        // fully current even though everything already streamed.
        let events = await renderer.subscribe()
        var laidOut = Set<BlockID>()
        var sawSnapshot = false
        for await event in events {
            switch event {
            case .document(let delta):
                if delta.document.isComplete, delta.insertedBlockIDs.count == 2 {
                    sawSnapshot = true
                }
            case .layout(let commit):
                laidOut.insert(commit.key.blockID)
            }
            if sawSnapshot, laidOut.isSuperset(of: expectedIDs) { break }
        }
        #expect(sawSnapshot)
        #expect(laidOut.isSuperset(of: expectedIDs))
        await renderer.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func twoSubscribersBothReceiveEvents() async throws {
        let renderer = MessageStreamRenderer(
            messageID: MessageID("multi-sub"),
            width: 320,
            coalesceInterval: .milliseconds(2)
        )
        await renderer.ingest("Hello multicast world.")
        await renderer.finishStream()

        let first = await renderer.subscribe()
        let second = await renderer.subscribe()

        func firstDocument(_ stream: AsyncStream<MessageStreamRenderer.Event>) async -> MarkdownDocument? {
            for await event in stream {
                if case .document(let delta) = event { return delta.document }
            }
            return nil
        }
        let documentA = await firstDocument(first)
        let documentB = await firstDocument(second)
        #expect(documentA?.blocks.count == 1)
        #expect(documentB?.blocks.count == 1)
        await renderer.shutdown()
    }

    /// Regression: empty-finish-watcher-hang. A subscriber attaching after an
    /// empty document completed must still receive the completion snapshot —
    /// otherwise height watchers for empty messages hang forever.
    @Test(.timeLimit(.minutes(1)))
    func emptyCompletedDocumentSnapshotIsReplayedToLateSubscriber() async {
        let renderer = MessageStreamRenderer(
            messageID: MessageID("empty-msg"),
            width: 320,
            coalesceInterval: .milliseconds(2)
        )
        await renderer.finishStream() // no content ever ingested

        let events = await renderer.subscribe()
        var received: MarkdownDocument?
        for await event in events {
            if case .document(let delta) = event {
                received = delta.document
                break
            }
        }
        #expect(received?.isComplete == true)
        #expect(received?.blocks.isEmpty == true)
        await renderer.shutdown()
    }

    /// Regression: forwarding-task-and-scheduler-subscriber-leak. Dropping the
    /// last reference to a renderer must cancel its forwarding task, which in
    /// turn must remove the scheduler-side subscriber entry.
    @Test(.timeLimit(.minutes(1)))
    func discardedRendererRemovesItsSchedulerSubscriber() async throws {
        let scheduler = BlockLayoutScheduler()
        var renderer: MessageStreamRenderer? = MessageStreamRenderer(
            messageID: MessageID("leak-check"),
            width: 320,
            coalesceInterval: .milliseconds(2),
            scheduler: scheduler
        )
        await renderer?.ingest("Some streamed text.")
        await renderer?.finishStream()
        #expect(await scheduler.subscriberCount == 1)

        renderer = nil
        // Teardown is asynchronous (onTermination hops back to the actor);
        // the time limit bounds this loop if the chain is broken.
        while await scheduler.subscriberCount != 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await scheduler.subscriberCount == 0)
    }

    /// Regression: forwarding-task-and-scheduler-subscriber-leak (window
    /// release path). `releaseMessage` must finish and remove subscribers
    /// filtered to that message, and leave everyone else untouched.
    @Test(.timeLimit(.minutes(1)))
    func releaseMessageReclaimsThatMessagesSubscribers() async {
        let scheduler = BlockLayoutScheduler()
        let released = await scheduler.commits(for: MessageID("gone"))
        let kept = await scheduler.commits(for: MessageID("kept"))
        let unfiltered = await scheduler.commits()
        #expect(await scheduler.subscriberCount == 3)

        await scheduler.releaseMessage(MessageID("gone"))
        #expect(await scheduler.subscriberCount == 2)

        // The released stream is finished, not left hanging.
        var iterator = released.makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
        withExtendedLifetime((kept, unfiltered)) {}
    }

    /// Regression companion: after a window release finishes its forwarding
    /// stream, a renderer must re-register on the next subscribe so a released
    /// message that scrolls back into view still receives layout commits.
    @Test(.timeLimit(.minutes(1)))
    func rendererReregistersForwardingAfterWindowRelease() async throws {
        let scheduler = BlockLayoutScheduler()
        let id = MessageID("windowed")
        let renderer = MessageStreamRenderer(
            messageID: id,
            width: 320,
            coalesceInterval: .milliseconds(2),
            scheduler: scheduler
        )
        await renderer.ingest("Windowed message body.")
        await renderer.finishStream()
        #expect(await renderer.isForwardingRegistered)

        await scheduler.releaseMessage(id)
        // The forwarding task unwinds asynchronously; wait until the renderer
        // notices its stream ended.
        while await renderer.isForwardingRegistered {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await scheduler.subscriberCount == 0)

        // A fresh subscription (cell rebind) must re-register forwarding and
        // replay layout commits for the recomputed blocks.
        let events = await renderer.subscribe()
        var sawLayout = false
        for await event in events {
            if case .layout = event {
                sawLayout = true
                break
            }
        }
        #expect(sawLayout)
        #expect(await renderer.isForwardingRegistered)
        #expect(await scheduler.subscriberCount == 1)
        await renderer.shutdown()
    }
}

/// The identity contract behind StreamingMarkdownView's lineage suffix: a
/// MessageID names ONE streaming lineage. A second assembler with the same ID
/// re-issues the same (birthOrder, revision) keys for different content, so
/// the shared cache serves the first lineage's layouts — this test pins the
/// failure mode (observed in the Enchanted integration as messages collapsing
/// to their first few words) and the releaseMessage remedy.
struct MessageIdentityContractTests {
    @Test func reusedMessageIDServesStaleLayoutsUnlessReleased() async throws {
        let scheduler = BlockLayoutScheduler()
        let environment = RenderEnvironment()

        // Lineage 1 streams: block 0 revision 0 is just the first few words.
        let first = StreamingMessageAssembler(messageID: MessageID("contract"))
        let firstDelta = first.append("Hello world, the first")
        try #require(firstDelta.document.blocks.count == 1)
        let firstBlock = firstDelta.document.blocks[0]
        #expect(firstBlock.revision == .zero)

        var iterator = await scheduler.commits().makeAsyncIterator()
        await scheduler.requestLayout(for: firstBlock, width: 320, theme: .default, environment: environment)
        _ = await iterator.next()

        // Lineage 2 reuses the ID and ingests the full text in one parse:
        // block 0 is ALSO at revision 0, but with different content.
        let second = StreamingMessageAssembler(messageID: MessageID("contract"))
        let secondDelta = second.append("Hello world, the first few words plus the rest of a much longer sentence.")
        try #require(secondDelta.document.blocks.count == 1)
        let secondBlock = secondDelta.document.blocks[0]
        #expect(secondBlock.id == firstBlock.id)
        #expect(secondBlock.revision == firstBlock.revision)

        await scheduler.requestLayout(for: secondBlock, width: 320, theme: .default, environment: environment)
        let stale = await iterator.next()
        // The cache cannot tell the lineages apart: it serves lineage 1's
        // few-words layout for lineage 2's full sentence.
        #expect(stale?.fromCache == true)
        #expect(stale?.result.accessibility.label == "Hello world, the first")

        // Remedy: releasing the retired lineage forces a fresh compute.
        await scheduler.releaseMessage(MessageID("contract"))
        await scheduler.requestLayout(for: secondBlock, width: 320, theme: .default, environment: environment)
        let fresh = await iterator.next()
        #expect(fresh?.fromCache == false)
        #expect(fresh?.result.accessibility.label == "Hello world, the first few words plus the rest of a much longer sentence.")
    }
}
