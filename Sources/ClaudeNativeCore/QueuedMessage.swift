import Foundation

/// A message held by the app before it is written to the CLI. Its text
/// can still be edited and its attachments can still be canceled with it.
public struct QueuedMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public let images: [ImageAttachment]

    public init(id: UUID = UUID(), text: String, images: [ImageAttachment] = []) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.images = images
    }

    public var isEmpty: Bool { text.isEmpty && images.isEmpty }
    public var transcriptText: String {
        ([text] + images.map { "Attached image: \($0.name)" }).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
