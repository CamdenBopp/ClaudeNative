import Foundation

/// Decodes UTF-8 that arrives in pieces, as a terminal's reads do: a
/// character split between two pieces waits for the rest instead of coming
/// out as two replacement characters.
public struct UTF8Chunks: Sendable {
    /// The start of a character whose remaining bytes haven't arrived.
    private var pending: [UInt8] = []
    /// A UTF-8 character is at most this many bytes.
    static let longestCharacter = 4

    public init() {}

    public mutating func decode<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> String {
        let data = pending + bytes
        let cut = Self.completeLength(data)
        pending = Array(data[cut...])
        return String(decoding: data[..<cut], as: UTF8.self)
    }

    /// How much of `data` ends on a character boundary: all of it, unless
    /// it ends partway into a character that more bytes would complete.
    static func completeLength(_ data: [UInt8]) -> Int {
        var index = data.count - 1
        var continuations = 0
        while index >= 0, continuations < longestCharacter {
            let byte = data[index]
            guard byte & 0xC0 == 0x80 else {
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return data.count - index < length ? index : data.count
            }
            continuations += 1
            index -= 1
        }
        return data.count
    }
}
