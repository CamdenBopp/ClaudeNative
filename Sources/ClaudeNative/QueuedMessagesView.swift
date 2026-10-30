import ClaudeNativeCore
import SwiftUI

/// Messages sent while Claude works, above the composer: one line naming
/// the next, or every message with Edit and Remove when expanded.
struct QueuedMessagesView: View {
    /// The expanded list's height before it scrolls, about three messages.
    static let listIdealHeight: CGFloat = 120
    static let listMaxHeight: CGFloat = 160
    /// How much of a message an Edit or Remove button's name quotes.
    static let quotedLength = 60

    static func preview(_ message: QueuedMessage) -> String {
        message.text.isEmpty
            ? "\(message.images.count) attached \(message.images.count == 1 ? "image" : "images")"
            : message.text
    }

    /// An image-only message has no text to quote. Its file names identify
    /// which message Edit or Remove acts on.
    static func actionSummary(_ message: QueuedMessage) -> String {
        let summary = message.text.isEmpty ? message.images.map(\.name).joined(separator: ", ") : message.text
        return String(summary.prefix(quotedLength))
    }

    let model: AppModel
    var interactionEnded: () -> Void = {}
    @State private var expanded = false
    @AppStorage(TextScale.defaultsKey) private var textScale = TextScale.standard.factor

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                // The system disclosure: VoiceOver reads its name, then
                // collapsed or expanded, as for any disclosure triangle.
                // It stays open while a message is edited. Disabling it
                // instead disabled everything inside, Cancel Edit included.
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded },
                    set: { if model.editingQueuedMessageID == nil { expanded = $0 } }
                )) {
                    list
                } label: {
                    Text("\(model.queuedMessages.count) queued \(model.queuedMessages.count == 1 ? "message" : "messages")")
                }
                if model.queueIsPaused {
                    Text("Paused")
                        .foregroundStyle(Color(nsColor: Theme.quietLabel))
                    Button(model.isReady ? "Resume" : "Reconnect") {
                        model.resumeQueuedMessages()
                        interactionEnded()
                    }
                    .disabled(model.isWorking || model.editingQueuedMessageID != nil)
                } else if !model.isReady {
                    ProgressView("Reconnecting…")
                        .controlSize(.small)
                }
            }
            if !expanded, let next = model.queuedMessages.first {
                Text(Self.preview(next))
                    .lineLimit(1)
                    .foregroundStyle(Color(nsColor: Theme.quietLabel))
            }
        }
        .font(.system(size: Theme.conversationTextSize(.body, scale: textScale)))
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: Theme.readingWidth(scale: textScale))
        .background(Color(nsColor: Theme.cardFill), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.top, Theme.Spacing.small)
        .onAppear { if model.editingQueuedMessageID != nil { expanded = true } }
        .onChange(of: model.editingQueuedMessageID) { if model.editingQueuedMessageID != nil { expanded = true } }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                ForEach(model.queuedMessages) { message in
                    QueuedMessageRow(message: message, isEditing: model.editingQueuedMessageID == message.id,
                                     text: model.queuedEditingText ?? message.text,
                                     editDisabled: model.editingQueuedMessageID != nil,
                                     edit: { model.beginEditingQueuedMessage(message.id) },
                                     changeText: { model.updateQueuedMessageDraft(message.id, text: $0) },
                                     save: { text in
                                         model.updateQueuedMessage(message.id, text: text)
                                         interactionEnded()
                                     },
                                     cancelEdit: {
                                         model.cancelEditingQueuedMessage()
                                         interactionEnded()
                                     },
                                     remove: {
                                         model.cancelQueuedMessage(message.id)
                                         interactionEnded()
                                         Announcer.announceAfterFocusMove("Queued message removed.")
                                     })
                }
            }
        }
        .accessibilityLabel("Queued messages")
        .frame(idealHeight: Self.listIdealHeight, maxHeight: Self.listMaxHeight)
    }
}

private struct QueuedMessageRow: View {
    let message: QueuedMessage
    let isEditing: Bool
    let text: String
    let editDisabled: Bool
    let edit: () -> Void
    let changeText: (String) -> Void
    let save: (String) -> Void
    let cancelEdit: () -> Void
    let remove: () -> Void
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if isEditing {
                TextField("Edit queued message", text: Binding(get: { text }, set: changeText), axis: .vertical)
                    .accessibilityLabel("Edit queued message")
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($editorFocused)
                HStack {
                    Button("Cancel Edit", action: cancelEdit)
                    Button("Save Message") { save(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.images.isEmpty)
                }
            } else {
                HStack(alignment: .top) {
                    Text(QueuedMessagesView.preview(message))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit", action: edit).disabled(editDisabled)
                        .accessibilityLabel("Edit queued message: \(QueuedMessagesView.actionSummary(message))")
                    Button("Remove", action: remove)
                        .accessibilityLabel("Remove queued message: \(QueuedMessagesView.actionSummary(message))")
                }
            }
            if !message.images.isEmpty {
                Text(message.images.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: Theme.quietLabel))
            }
        }
        .onChange(of: isEditing) {
            if isEditing {
                editorFocused = true
            }
        }
    }
}
