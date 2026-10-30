import CoreGraphics
import Testing
@testable import ChatMarkdownCore

struct MessageRangePolicyTests {
    /// 100 items × 100pt, no spacing: item i spans [100i, 100i+100).
    private let geometry = ChatListGeometry(heights: Array(repeating: 100, count: 100), spacing: 0)
    private let policy = MessageRangePolicy()

    @Test func statesNestVisibleWithinDisplayWithinPreload() {
        // Viewport over items 50..53 (y 5000..5400).
        let states = policy.states(
            geometry: geometry, viewportMinY: 5000, viewportHeight: 400, velocity: 0
        )
        #expect(states.count == 100)
        for index in 50...53 {
            #expect(states[index] == .visible, "index \(index)")
        }
        // Every non-cold state must be contiguous around the viewport, and
        // ordering must nest: visible ⊂ displayReady ⊂ preload.
        let firstWarm = states.firstIndex { $0 > .cold }!
        let lastWarm = states.lastIndex { $0 > .cold }!
        for index in firstWarm...lastWarm {
            #expect(states[index] > .cold)
        }
        let firstDisplay = states.firstIndex { $0 >= .displayReady }!
        let firstPreload = states.firstIndex { $0 >= .preload }!
        #expect(firstPreload <= firstDisplay)
        #expect(firstDisplay <= 50)
        // Far-away items are cold.
        #expect(states[0] == .cold)
        #expect(states[99] == .cold)
    }

    @Test func bandsAreMeasuredInViewportMultiples() {
        // Defaults, velocity 0: displayReady reaches 1.5 viewports behind and
        // 3 ahead; preload 3 behind and 8 ahead.
        let states = policy.states(
            geometry: geometry, viewportMinY: 5000, viewportHeight: 400, velocity: 0
        )
        // Display band: y in [5000 - 600, 5400 + 1200] = [4400, 6600] → items 44..65.
        #expect(states[44] >= .displayReady)
        #expect(states[43] < .displayReady)
        #expect(states[65] >= .displayReady)
        #expect(states[66] < .displayReady)
        // Preload band: y in [5000 - 1200, 5400 + 3200] = [3800, 8600] → items 38..85.
        #expect(states[38] == .preload)
        #expect(states[37] == .cold)
        #expect(states[85] == .preload)
        #expect(states[86] == .cold)
    }

    @Test func velocityBiasesAheadInScrollDirection() {
        let still = policy.states(
            geometry: geometry, viewportMinY: 5000, viewportHeight: 400, velocity: 0
        )
        let flingDown = policy.states(
            geometry: geometry, viewportMinY: 5000, viewportHeight: 400, velocity: 5000
        )
        let flingUp = policy.states(
            geometry: geometry, viewportMinY: 5000, viewportHeight: 400, velocity: -5000
        )
        func warmExtent(_ states: [MessageRangeState]) -> (first: Int, last: Int) {
            (states.firstIndex { $0 > .cold }!, states.lastIndex { $0 > .cold }!)
        }
        let stillExtent = warmExtent(still)
        let downExtent = warmExtent(flingDown)
        let upExtent = warmExtent(flingUp)
        // Fling toward the end warms further below; the behind extent doesn't
        // shrink with speed (only "ahead" interpolates), so `first` holds.
        #expect(downExtent.last > stillExtent.last)
        #expect(downExtent.first >= stillExtent.first)
        // Fling toward the start flips the bands: more warmth above, only
        // the behind allowance below.
        #expect(upExtent.first < stillExtent.first)
        #expect(upExtent.last < stillExtent.last)
    }

    @Test func velocityInterpolationIsMonotonic() {
        func aheadCount(_ velocity: CGFloat) -> Int {
            let states = policy.states(
                geometry: geometry, viewportMinY: 2000, viewportHeight: 400, velocity: velocity
            )
            return states[24...].filter { $0 > .cold }.count
        }
        let slow = aheadCount(0)
        let mid = aheadCount(1500)
        let fast = aheadCount(10_000)
        #expect(slow <= mid)
        #expect(mid <= fast)
        #expect(fast > slow)
    }

    @Test func hugeSingleMessageSpansAllBands() {
        // One 50,000pt message: whatever band it intersects, it must get the
        // highest applicable state — count-based policies get this wrong.
        let huge = ChatListGeometry(heights: [50_000], spacing: 0)
        let states = policy.states(
            geometry: huge, viewportMinY: 20_000, viewportHeight: 400, velocity: 0
        )
        #expect(states == [.visible])
    }

    @Test func degenerateInputsAreSafe() {
        #expect(policy.states(
            geometry: ChatListGeometry(), viewportMinY: 0, viewportHeight: 400
        ).isEmpty)
        let zeroViewport = policy.states(
            geometry: geometry, viewportMinY: 0, viewportHeight: 0
        )
        #expect(zeroViewport.allSatisfy { $0 == .cold })
    }
}
