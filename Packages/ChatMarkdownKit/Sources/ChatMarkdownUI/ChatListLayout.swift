#if canImport(UIKit)
import UIKit
import ChatMarkdownCore

/// Single-column collection layout driven entirely by an authoritative
/// `ChatListGeometry` — no self-sizing, no estimated-height feedback loops.
/// The controller computes heights (exactly, off-main), builds a geometry,
/// assigns it here, and applies scroll compensation itself.
public final class ChatListLayout: UICollectionViewLayout {
    public var geometry = ChatListGeometry() {
        didSet { invalidateLayout() }
    }
    public var horizontalInset: CGFloat = 16

    public override var collectionViewContentSize: CGSize {
        CGSize(
            width: collectionView?.bounds.width ?? 0,
            height: geometry.contentHeight
        )
    }

    public override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let indices = geometry.indices(intersectingMinY: rect.minY, maxY: rect.maxY)
        guard !indices.isEmpty else { return [] }
        return indices.compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }

    public override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < geometry.count else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        let width = max(0, (collectionView?.bounds.width ?? 0) - horizontalInset * 2)
        attributes.frame = CGRect(
            x: horizontalInset,
            y: geometry.minY(at: indexPath.item),
            width: width,
            height: geometry.height(at: indexPath.item)
        )
        return attributes
    }

    public override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        // Width changes need new frames; pure scrolling does not.
        newBounds.width != collectionView?.bounds.width
    }
}
#endif
