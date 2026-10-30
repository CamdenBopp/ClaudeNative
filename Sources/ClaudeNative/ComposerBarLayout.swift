import SwiftUI

/// Keep every composer control visible when the column narrows or text
/// grows. Controls wrap in reading order; model and sending controls stay
/// against the trailing edge of whichever row contains them.
struct ComposerBarLayout: Layout {
    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, view) in subviews.enumerated() {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            let gap = row.items.isEmpty ? 0 : Theme.Spacing.small
            if !row.items.isEmpty, row.width + gap + size.width > width {
                rows.append(row)
                row = Row()
            }
            if !row.items.isEmpty { row.width += Theme.Spacing.small }
            row.items.append((index, size))
            row.width += size.width
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let gaps = CGFloat(max(0, subviews.count - 1)) * Theme.Spacing.small
        // A zero-width proposal asks for the minimum size. Counting every
        // control on its own row here made that worst-case height the
        // window's minimum, even when the real column had ample width.
        if proposal.width == 0 {
            return CGSize(width: 0, height: sizes.map(\.height).max() ?? 0)
        }
        let idealWidth = sizes.reduce(0) { $0 + $1.width } + gaps
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? idealWidth
        // Maximum-size queries must allow the height of every control on
        // its own row. A one-row maximum constrained the hosting view to
        // that height even after a narrower column needed more rows.
        if proposal.height == .infinity {
            return CGSize(width: width, height: sizes.reduce(0) { $0 + $1.height } + gaps)
        }
        let rows = rows(in: width, subviews: subviews)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * Theme.Spacing.small)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews: subviews) {
            var x = bounds.minX
            var alignedTrailingControls = false
            for item in row.items {
                let view = subviews[item.index]
                if view[ComposerBarTrailingControl.self], !alignedTrailingControls {
                    x += max(0, bounds.width - row.width)
                    alignedTrailingControls = true
                }
                view.place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), anchor: .topLeading,
                           proposal: ProposedViewSize(item.size))
                x += item.size.width + Theme.Spacing.small
            }
            y += row.height + Theme.Spacing.small
        }
    }
}

enum ComposerBarTrailingControl: LayoutValueKey {
    static let defaultValue = false
}
