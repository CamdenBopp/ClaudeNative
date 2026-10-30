import Foundation

/// Where you were reading a conversation: the row at the top of the view
/// and how far down it the view started, as a share of its height, so the
/// place survives a different window width or text size.
struct TranscriptPosition: Codable, Equatable {
    let entryID: String
    let fraction: Double
    var updatedAt = Date()
}

/// Reading positions by session id, kept in preferences. A conversation
/// left at its end has none, so it reopens at the end.
@MainActor
final class TranscriptPositionStore {
    static let shared = TranscriptPositionStore()
    static let defaultsKey = "transcriptPositions.v1"
    /// Sessions remembered; reading a newer one forgets the oldest.
    static let capacity = 200

    private let defaults: UserDefaults
    private var positions: [String: TranscriptPosition]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        positions = defaults.data(forKey: Self.defaultsKey).flatMap {
            try? JSONDecoder().decode([String: TranscriptPosition].self, from: $0)
        } ?? [:]
    }

    func position(for sessionID: String) -> TranscriptPosition? { positions[sessionID] }

    /// Saves where `sessionID` was being read; nil means at its end.
    func save(_ position: TranscriptPosition?, for sessionID: String) {
        guard positions[sessionID] != position else { return }
        positions[sessionID] = position
        if positions.count > Self.capacity {
            let recent = positions.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(Self.capacity)
            positions = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(positions) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
