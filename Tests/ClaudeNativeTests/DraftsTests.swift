import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// The message field follows the conversation, not the window.
struct DraftsTests {
    @Test func aDraftStaysWithItsSession() {
        var drafts = Drafts()
        let image = ImageAttachment(name: "secret.png", mediaType: "image/png", data: Data([1]))
        let typed = Drafts.Draft(text: "fix this", attachments: [image])
        // Leaving A for B: B's field is empty, not A's draft.
        #expect(drafts.switching(from: "A", keeping: typed, to: "B") == Drafts.Draft())
        // Back to A: its draft returns.
        #expect(drafts.switching(from: "B", keeping: Drafts.Draft(), to: "A") == typed)
        // A new conversation starts empty too.
        #expect(drafts.switching(from: "A", keeping: typed, to: nil) == Drafts.Draft())
    }

    @Test func queuedMessagesAreKeptInTheDraft() {
        let image = ImageAttachment(name: "shot.png", mediaType: "image/png", data: Data([1]))
        let queued = [QueuedMessage(text: "second"), QueuedMessage(text: "third", images: [image])]
        let kept = Drafts.Draft(text: "half typed").keeping(queued: queued)
        #expect(kept.text == "second\n\nthird\n\nhalf typed")
        #expect(kept.attachments == [image])
        #expect(Drafts.Draft().keeping(queued: []) == Drafts.Draft())
    }
}
