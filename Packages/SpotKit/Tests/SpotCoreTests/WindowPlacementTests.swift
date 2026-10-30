import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import SpotCore

@Suite struct WindowPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let capsule = CGSize(width: 480, height: 56)
    let card = CGSize(width: 480, height: 560)

    @Test func defaultPositionIsCenteredInTheLowerPart() {
        let corner = WindowPlacement.defaultBottomLeft(width: 480, visibleFrame: screen)
        let frame = WindowPlacement.frame(bottomLeft: corner, size: capsule, visibleFrame: screen)
        #expect(frame.midX == screen.midX)
        #expect(frame.minY == 198)
        #expect(frame.minY + card.height <= screen.maxY, "The card fits above")
    }

    @Test func cardGrowsUpFromTheInputAndShrinksBackToIt() {
        let corner = CGPoint(x: 300, y: 150)
        let capsuleFrame = WindowPlacement.frame(bottomLeft: corner, size: capsule, visibleFrame: screen)
        let cardFrame = WindowPlacement.frame(bottomLeft: corner, size: card, visibleFrame: screen)
        #expect(cardFrame.minY == capsuleFrame.minY)
        #expect(cardFrame.maxY == capsuleFrame.minY + 560)
        #expect(cardFrame.minX == capsuleFrame.minX)
        #expect(WindowPlacement.frame(bottomLeft: corner, size: capsule, visibleFrame: screen) == capsuleFrame)
    }

    @Test func aCardWithoutRoomAboveSlidesDown() {
        let corner = CGPoint(x: 300, y: 600)
        let cardFrame = WindowPlacement.frame(bottomLeft: corner, size: card, visibleFrame: screen)
        #expect(cardFrame.maxY == screen.maxY)
        #expect(cardFrame.height == 560)
    }

    @Test func aPositionOffScreenIsPulledBack() {
        let frame = WindowPlacement.frame(bottomLeft: CGPoint(x: 2000, y: -300), size: capsule, visibleFrame: screen)
        #expect(screen.contains(frame))
    }

    @Test func secondaryScreenWithOffsetOrigin() {
        let external = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let corner = WindowPlacement.defaultBottomLeft(width: 480, visibleFrame: external)
        let frame = WindowPlacement.frame(bottomLeft: corner, size: capsule, visibleFrame: external)
        #expect(frame.midX == external.midX)
        #expect(external.contains(frame))
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
