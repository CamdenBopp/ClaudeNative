import CoreGraphics
import Testing
@testable import ChatMarkdownCore

struct ChatListGeometryTests {
    @Test func framesStackWithSpacing() {
        let geometry = ChatListGeometry(heights: [100, 50, 200], spacing: 16)
        #expect(geometry.minY(at: 0) == 0)
        #expect(geometry.minY(at: 1) == 116)
        #expect(geometry.minY(at: 2) == 182)
        #expect(geometry.contentHeight == 382)
    }

    @Test func emptyGeometryIsSafe() {
        let geometry = ChatListGeometry()
        #expect(geometry.contentHeight == 0)
        #expect(geometry.anchorIndex(forY: 100) == nil)
        #expect(geometry.indices(intersectingMinY: 0, maxY: 500).isEmpty)
    }

    @Test func anchorIndexFindsOccupyingItem() {
        let geometry = ChatListGeometry(heights: [100, 100, 100], spacing: 10)
        #expect(geometry.anchorIndex(forY: -50) == 0)   // above content
        #expect(geometry.anchorIndex(forY: 0) == 0)
        #expect(geometry.anchorIndex(forY: 99) == 0)
        #expect(geometry.anchorIndex(forY: 105) == 1)   // inside the gap → next item
        #expect(geometry.anchorIndex(forY: 110) == 1)
        #expect(geometry.anchorIndex(forY: 9_999) == 2) // below content → last
    }

    @Test func intersectionRangeCoversViewport() {
        let geometry = ChatListGeometry(heights: Array(repeating: 100, count: 50), spacing: 10)
        // Viewport over items 3..6 (item i spans [110i, 110i+100]).
        let range = geometry.indices(intersectingMinY: 350, maxY: 700)
        #expect(range == 3..<7)
        // Degenerate viewport before content.
        #expect(geometry.indices(intersectingMinY: -500, maxY: -100).isEmpty)
    }

    @Test func compensationTracksAnchorMovement() {
        let old = ChatListGeometry(heights: [100, 50, 200, 80], spacing: 16)
        // Item 1 above the anchor grows by 40.
        let new = ChatListGeometry(heights: [100, 90, 200, 80], spacing: 16)
        #expect(ChatListGeometry.compensation(from: old, to: new, anchorIndex: 2) == 40)
        // Growth below the anchor doesn't move it.
        let below = ChatListGeometry(heights: [100, 50, 200, 800], spacing: 16)
        #expect(ChatListGeometry.compensation(from: old, to: below, anchorIndex: 2) == 0)
        #expect(ChatListGeometry.compensation(from: old, to: new, anchorIndex: nil) == 0)
    }
}

struct ChatScrollPolicyTests {
    @Test func nearBottomThreshold() {
        // Content 1000, viewport 400 → max offset 600.
        #expect(ChatScrollPolicy.isNearBottom(offsetY: 600, contentHeight: 1000, viewportHeight: 400))
        #expect(ChatScrollPolicy.isNearBottom(offsetY: 570, contentHeight: 1000, viewportHeight: 400))
        #expect(!ChatScrollPolicy.isNearBottom(offsetY: 500, contentHeight: 1000, viewportHeight: 400))
        // Short content: always near bottom.
        #expect(ChatScrollPolicy.isNearBottom(offsetY: 0, contentHeight: 200, viewportHeight: 400))
    }

    @Test func followingPinsToBottomAsContentGrows() {
        let target = ChatScrollPolicy.targetOffsetY(
            previousOffsetY: 600,
            anchorCompensation: 0,
            followBottom: true,
            contentHeight: 1400,
            viewportHeight: 400
        )
        #expect(target == 1000)
    }

    @Test func readingPositionSurvivesGrowthBelow() {
        // User reading at offset 250; the streaming message grows below.
        let target = ChatScrollPolicy.targetOffsetY(
            previousOffsetY: 250,
            anchorCompensation: 0,
            followBottom: false,
            contentHeight: 5000,
            viewportHeight: 400
        )
        #expect(target == 250)
    }

    @Test func readingPositionCompensatesGrowthAbove() {
        // A late height correction added 60pt above the anchor.
        let target = ChatScrollPolicy.targetOffsetY(
            previousOffsetY: 250,
            anchorCompensation: 60,
            followBottom: false,
            contentHeight: 5000,
            viewportHeight: 400
        )
        #expect(target == 310)
    }

    @Test func targetsClampToValidRange() {
        // Compensation would push past the end.
        let target = ChatScrollPolicy.targetOffsetY(
            previousOffsetY: 550,
            anchorCompensation: 500,
            followBottom: false,
            contentHeight: 1000,
            viewportHeight: 400
        )
        #expect(target == 600)
        // Content shorter than the viewport clamps to the top inset.
        let short = ChatScrollPolicy.targetOffsetY(
            previousOffsetY: 100,
            anchorCompensation: -300,
            followBottom: false,
            contentHeight: 200,
            viewportHeight: 400,
            topInset: 12
        )
        #expect(short == -12)
    }

    @Test func insetsShiftTheBottomPin() {
        let target = ChatScrollPolicy.targetOffsetY(
            previousOffsetY: 0,
            anchorCompensation: 0,
            followBottom: true,
            contentHeight: 1000,
            viewportHeight: 400,
            topInset: 12,
            bottomInset: 34
        )
        #expect(target == 634)
    }
}
