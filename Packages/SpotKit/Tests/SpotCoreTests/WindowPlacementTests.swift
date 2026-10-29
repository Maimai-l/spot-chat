import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import SpotCore

@Suite struct WindowPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let capsule = CGSize(width: 480, height: 56)

    @Test func defaultPositionIsCenteredNearTheTop() {
        let frame = WindowPlacement.initialFrame(size: capsule, savedTopLeft: nil, visibleFrame: screen)
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY == 720)
    }

    @Test func usesTheDraggedPosition() {
        let saved = CGPoint(x: 100, y: 500)
        let frame = WindowPlacement.initialFrame(size: capsule, savedTopLeft: saved, visibleFrame: screen)
        #expect(WindowPlacement.topLeft(of: frame) == saved)
    }

    @Test func draggedPositionOffScreenIsPulledBack() {
        let frame = WindowPlacement.initialFrame(size: capsule, savedTopLeft: CGPoint(x: 2000, y: 1200), visibleFrame: screen)
        #expect(screen.contains(frame))
    }

    @Test func secondaryScreenWithOffsetOrigin() {
        let external = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let frame = WindowPlacement.initialFrame(size: capsule, savedTopLeft: nil, visibleFrame: external)
        #expect(frame.midX == external.midX)
        #expect(external.contains(frame))
    }

    @Test func expandingKeepsTopEdgeAndGrowsDown() {
        let start = WindowPlacement.initialFrame(size: capsule, savedTopLeft: nil, visibleFrame: screen)
        let card = WindowPlacement.expandedFrame(from: start, toHeight: 560, visibleFrame: screen)
        #expect(card.maxY == start.maxY)
        #expect(card.height == 560)
        #expect(card.minX == start.minX)
    }

    @Test func expandingNearTheBottomMovesTheCardUp() {
        let low = CGRect(x: 200, y: 100, width: 480, height: 56)
        let card = WindowPlacement.expandedFrame(from: low, toHeight: 560, visibleFrame: screen)
        #expect(card.minY == screen.minY)
        #expect(card.height == 560)
    }

    @Test func collapsingKeepsTopEdge() {
        let card = CGRect(x: 200, y: 160, width: 480, height: 560)
        let collapsed = WindowPlacement.collapsedFrame(from: card, toHeight: 56)
        #expect(collapsed.maxY == card.maxY)
        #expect(collapsed.height == 56)
    }
}

@Suite struct DragTrackerTests {
    @Test func smallMovementIsAClick() {
        var tracker = DragTracker(start: .zero, threshold: 3)
        #expect(tracker.update(to: CGPoint(x: 1, y: 2)) == nil)
        #expect(!tracker.isDragging)
    }

    @Test func movementPastThresholdStartsDragWithFullOffset() {
        var tracker = DragTracker(start: CGPoint(x: 10, y: 10), threshold: 3)
        #expect(tracker.update(to: CGPoint(x: 14, y: 10)) == CGSize(width: 4, height: 0))
        #expect(tracker.isDragging)
        #expect(tracker.update(to: CGPoint(x: 11, y: 10)) == CGSize(width: 1, height: 0))
    }
}
