import SwiftUI

/// An icon-only button's label: the symbol, centered in a square at least
/// `Theme.iconButtonSize` across. A borderless button is only as big as
/// its label, so with the plain icon-only style it was the size of its
/// glyph: Close Editor measured 10 by 10 points and Back 6 by 12.
///
/// `alignment` keeps the glyph where it sat before the target grew: a
/// button at the start of a row takes `.leading`, one at the end
/// `.trailing`, so only the clickable area changes, not the layout.
struct IconTargetLabelStyle: LabelStyle {
    var alignment: Alignment = .center

    func makeBody(configuration: Configuration) -> some View {
        // The icon-only label keeps the title as the button's name.
        Label(configuration)
            .labelStyle(.iconOnly)
            .frame(minWidth: Theme.iconButtonSize, minHeight: Theme.iconButtonSize, alignment: alignment)
            .contentShape(Rectangle())
    }
}

extension LabelStyle where Self == IconTargetLabelStyle {
    static var iconTarget: IconTargetLabelStyle { IconTargetLabelStyle() }
    static func iconTarget(_ alignment: Alignment) -> IconTargetLabelStyle { IconTargetLabelStyle(alignment: alignment) }
}
