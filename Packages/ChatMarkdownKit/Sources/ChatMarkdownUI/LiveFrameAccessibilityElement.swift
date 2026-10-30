#if canImport(UIKit)
import UIKit

/// A `UIAccessibilityElement` whose `accessibilityFrame` — the screen-space
/// rect VoiceOver's focus highlight and explore-by-touch hit-testing actually
/// use — is computed fresh at query time from a live view and a rect in that
/// view's own bounds space, instead of the framework's `accessibilityContainer`
/// + `accessibilityFrameInContainerSpace` conversion.
///
/// That implicit path was found to not reliably track live geometry once the
/// container is a UIKit view hosted through a SwiftUI `UIViewRepresentable`
/// inside a `ScrollView`: VoiceOver spoke the correct label (swipe navigation
/// is order-based and needs no frame), but explore-by-touch found nothing at
/// the actual on-screen text, and the focus highlight drew away from it.
/// Converting explicitly via `UIAccessibility.convertToScreenCoordinates`
/// on every read sidesteps whatever the implicit path was getting wrong.
open class LiveFrameAccessibilityElement: UIAccessibilityElement {
    public weak var referenceView: UIView?
    public var localFrame: CGRect = .zero

    open override var accessibilityFrame: CGRect {
        get {
            guard let referenceView else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(localFrame, in: referenceView)
        }
        set {
            // Computed live from referenceView + localFrame on every read;
            // external writes (none in this codebase) would be silently lost.
        }
    }
}
#endif
