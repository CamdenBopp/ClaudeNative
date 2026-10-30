import Foundation

/// Permission requests waiting for the user, oldest first. The CLI can ask
/// about several tool calls before the first is answered, and each must get
/// its own answer or that call waits forever.
public struct PermissionQueue: Sendable, Equatable {
    public private(set) var waiting: [PermissionRequest] = []

    public init() {}

    /// The request to show now.
    public var current: PermissionRequest? { waiting.first }

    public mutating func enqueue(_ request: PermissionRequest) {
        guard !waiting.contains(where: { $0.requestID == request.requestID }) else { return }
        waiting.append(request)
    }

    /// Takes `requestID` out once it has been answered.
    @discardableResult
    public mutating func resolve(_ requestID: String) -> PermissionRequest? {
        guard let index = waiting.firstIndex(where: { $0.requestID == requestID }) else { return nil }
        return waiting.remove(at: index)
    }

    /// Drops everything, when the process that asked has ended and no
    /// answer can reach it.
    public mutating func clear() {
        waiting.removeAll()
    }

    /// Drops what the ended turn asked. A background agent's request stays:
    /// it isn't part of the turn and the CLI doesn't withdraw it, so
    /// dropping it left that agent waiting for ever.
    public mutating func clearTurn() {
        waiting.removeAll { $0.agentID == nil }
    }
}
