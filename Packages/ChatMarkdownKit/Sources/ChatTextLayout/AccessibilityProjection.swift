import CoreGraphics
import Foundation
import ChatMarkdownCore

/// Platform-neutral accessibility element model, projected from the same
/// blocks and layout results that drive drawing — never a second parse.
/// The UIKit layer maps these 1:1 onto `UIAccessibilityElement`s; keeping the
/// model here makes reading order, identity, and geometry testable on any
/// host.
///
/// Granularity strategy: prose blocks are one element each (paragraph-level
/// swiping, not word soup), a top-level list is one element per item (bullet-
/// level swiping, not "list, N items" as a single run-on sentence), links are
/// individually focusable and actionable elements placed after their block,
/// and code blocks are handled by the code subsystem's own chunked container
/// (see `CodeAccessibilityChunker`).
public struct AccessibleElementModel: Equatable, Sendable {
    /// Stable identity: same block + same slot ⇒ the UIKit layer reuses the
    /// same `UIAccessibilityElement` instance, so VoiceOver focus survives
    /// streaming label updates.
    public struct ID: Hashable, Sendable {
        public enum Slot: Hashable, Sendable {
            case body
            case listItem(Int)
            case link(Int)
        }

        public let blockID: BlockID
        public let slot: Slot

        public init(blockID: BlockID, slot: Slot) {
            self.blockID = blockID
            self.slot = slot
        }
    }

    public enum Kind: Equatable, Sendable {
        case blockText(BlockAccessibilityRole)
        case link(destination: String)
    }

    public let id: ID
    public let label: String
    /// Frame in the message container's coordinate space.
    public let frame: CGRect
    public let kind: Kind

    public init(id: ID, label: String, frame: CGRect, kind: Kind) {
        self.id = id
        self.label = label
        self.frame = frame
        self.kind = kind
    }
}

public enum AccessibilityProjector {
    /// Elements for one laid-out block, in reading order: the block body
    /// first, then each link — except a top-level list, where each link is
    /// interleaved right after the item it visually sits in, not batched
    /// after every item (otherwise a link in the first item would only be
    /// reachable after swiping through every other item first). Code blocks
    /// return nothing — the code view is its own accessibility container and
    /// is spliced into the element list by the message container.
    public static func elements(
        for block: MarkdownBlock,
        layout: BlockLayoutResult,
        origin: CGPoint
    ) -> [AccessibleElementModel] {
        guard block.content.kind != .codeBlock else { return [] }

        var output: [AccessibleElementModel] = []
        if layout.accessibility.role == .list, !layout.listItems.isEmpty {
            // Items are contiguous, non-overlapping, top-to-bottom bands, so
            // the last item whose top sits at or above a link's top is the
            // item that link visually belongs to.
            var linksByItem: [Int: [(index: Int, link: LinkRegion, frame: CGRect)]] = [:]
            for (index, link) in layout.links.enumerated() {
                let union = link.rects.reduce(CGRect.null) { $0.union($1) }
                guard !union.isNull else { continue }
                let itemIndex = layout.listItems.lastIndex { $0.frame.minY <= union.minY } ?? 0
                linksByItem[itemIndex, default: []].append((index, link, union))
            }
            for (index, item) in layout.listItems.enumerated() {
                output.append(AccessibleElementModel(
                    id: AccessibleElementModel.ID(blockID: block.id, slot: .listItem(index)),
                    label: item.label,
                    frame: item.frame.offsetBy(dx: origin.x, dy: origin.y),
                    kind: .blockText(layout.accessibility.role)
                ))
                for (linkIndex, link, frame) in linksByItem[index] ?? [] {
                    output.append(AccessibleElementModel(
                        id: AccessibleElementModel.ID(blockID: block.id, slot: .link(linkIndex)),
                        label: link.text.isEmpty ? link.destination : link.text,
                        frame: frame.offsetBy(dx: origin.x, dy: origin.y),
                        kind: .link(destination: link.destination)
                    ))
                }
            }
        } else {
            output.append(AccessibleElementModel(
                id: AccessibleElementModel.ID(blockID: block.id, slot: .body),
                label: layout.accessibility.label,
                frame: CGRect(origin: origin, size: layout.size),
                kind: .blockText(layout.accessibility.role)
            ))
            for (index, link) in layout.links.enumerated() {
                let union = link.rects.reduce(CGRect.null) { $0.union($1) }
                guard !union.isNull else { continue }
                output.append(AccessibleElementModel(
                    id: AccessibleElementModel.ID(blockID: block.id, slot: .link(index)),
                    label: link.text.isEmpty ? link.destination : link.text,
                    frame: union.offsetBy(dx: origin.x, dy: origin.y),
                    kind: .link(destination: link.destination)
                ))
            }
        }
        return output
    }
}
