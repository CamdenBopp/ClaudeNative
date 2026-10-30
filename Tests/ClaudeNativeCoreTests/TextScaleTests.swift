import Testing
@testable import ClaudeNativeCore

struct TextScaleTests {
    @Test func stepsUpAndDownAndStopsAtTheEnds() throws {
        let bigger = try #require(TextScale.standard.bigger)
        #expect(bigger.factor == 1.15)
        #expect(bigger.smaller == .standard)
        let largest = TextScale(TextScale.steps.last ?? 0)
        #expect(largest.bigger == nil)
        let smallest = TextScale(TextScale.steps.first ?? 0)
        #expect(smallest.smaller == nil)
    }

    @Test func offStepValuesSnapToTheNearestStep() {
        #expect(TextScale(1.2).factor == 1.15)
        #expect(TextScale(0).factor == 0.85)
        #expect(TextScale(40).factor == 3)
    }

    @Test func spokenAsAPercentage() {
        #expect(TextScale.standard.spoken == "Text size 100 percent")
        #expect(TextScale(1.15).spoken == "Text size 115 percent")
    }
}
