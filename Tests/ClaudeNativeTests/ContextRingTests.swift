import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// The composer's context ring, by the colors it's drawn in: the empty
/// ring reads against the card, and the filled arc against the empty ring.
/// (A lighter track was tried: 1.2:1 against the white card, so an almost
/// empty context showed as a stray tick.)
@MainActor
@Suite(.serialized) struct ContextRingTests {
    @Test(arguments: ThemeContrastTests.appearances)
    func theRingAndItsArcRead(appearance: String) {
        let card = ThemeContrastTests.resolved(Theme.composerFill, in: appearance)
        let track = ThemeContrastTests.over(ThemeContrastTests.resolved(Theme.contextRingTrack, in: appearance), card)
        let arc = ThemeContrastTests.resolved(.labelColor, in: appearance)
        #expect(ThemeContrastTests.ratio(track, card) >= 3)
        #expect(ThemeContrastTests.ratio(ThemeContrastTests.over(arc, card), track) >= 3)
    }
}
