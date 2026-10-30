/// Who authored a message. Pure presentation metadata: the document model and
/// layout are sender-agnostic; the conversation view maps a sender to a bubble
/// appearance (alignment, color, shape, padding) and the height/width pipeline
/// picks the matching geometry.
public enum MessageSender: Hashable, Sendable {
    case user
    case assistant
}
