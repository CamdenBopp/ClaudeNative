import ClaudeNativeCore

/// What's typed and attached in the message field, kept per conversation:
/// switching sessions carried the field over, so a draft and its images
/// went to whichever session was opened next, and coming back found it gone.
struct Drafts {
    struct Draft: Equatable {
        var text = ""
        var attachments: [ImageAttachment] = []

        /// This draft with messages still waiting in the queue folded in,
        /// as a session is left: leaving cleared the queue, and what was
        /// typed into it was gone for good.
        func keeping(queued: [QueuedMessage]) -> Draft {
            guard !queued.isEmpty else { return self }
            let texts = queued.map(\.text) + (text.isEmpty ? [] : [text])
            return Draft(text: texts.filter { !$0.isEmpty }.joined(separator: "\n\n"),
                         attachments: queued.flatMap(\.images) + attachments)
        }
    }

    /// By session id; a conversation not yet saved has none.
    private var saved: [String?: Draft] = [:]

    /// Keeps `current` for the conversation being left and returns the one
    /// last left in `next`, empty if there is none.
    mutating func switching(from leaving: String?, keeping current: Draft, to next: String?) -> Draft {
        saved[leaving] = current == Draft() ? nil : current
        return saved.removeValue(forKey: next) ?? Draft()
    }
}
