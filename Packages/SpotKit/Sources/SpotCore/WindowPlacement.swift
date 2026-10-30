import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Window frame math in AppKit screen coordinates (origin at the bottom left).
///
/// The mini window is placed by its bottom-left corner, where the input bar sits: the capsule grows
/// upward into the card and shrinks back down to the same spot, as Gemini's does, so the input never moves.
public enum WindowPlacement {
    /// Distance from the bottom of the screen's visible area to the bottom of the window,
    /// as a fraction of the visible height, leaving room above for the card.
    public static let defaultBottomFraction: CGFloat = 0.22

    /// Where the input bar goes when the user has not dragged it: centered, in the lower part of the screen.
    public static func defaultBottomLeft(width: CGFloat, visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: visibleFrame.midX - width / 2, y: visibleFrame.minY + visibleFrame.height * defaultBottomFraction)
    }

    /// The window with its bottom-left corner at the input bar's spot, moved only as far as needed to fit
    /// on screen; a card too tall for the room above slides down rather than off the top.
    public static func frame(bottomLeft: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
        clamp(CGRect(origin: bottomLeft, size: size), to: visibleFrame)
    }

    /// Moves a frame the smallest distance needed to lie inside `visibleFrame`.
    /// When it is taller or wider than the visible area, its top or left edge is kept inside.
    public static func clamp(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        var result = frame
        if result.maxX > visibleFrame.maxX { result.origin.x = visibleFrame.maxX - result.width }
        if result.minX < visibleFrame.minX { result.origin.x = visibleFrame.minX }
        if result.minY < visibleFrame.minY { result.origin.y = visibleFrame.minY }
        if result.maxY > visibleFrame.maxY { result.origin.y = visibleFrame.maxY - result.height }
        return result
    }

    public static func bottomLeft(of frame: CGRect) -> CGPoint {
        frame.origin
    }
}

/// Decides when a press turns into a window drag. Small movements below the threshold
/// are treated as a click, so buttons and text selection are not disturbed.
public struct DragTracker: Equatable, Sendable {
    public let start: CGPoint
    public let threshold: CGFloat
    public private(set) var isDragging = false

    public init(start: CGPoint, threshold: CGFloat = 3) {
        self.start = start
        self.threshold = threshold
    }

    /// Returns the offset from the press point once dragging has started, otherwise nil.
    public mutating func update(to point: CGPoint) -> CGSize? {
        let dx = point.x - start.x
        let dy = point.y - start.y
        if !isDragging {
            guard (dx * dx + dy * dy).squareRoot() >= threshold else { return nil }
            isDragging = true
        }
        return CGSize(width: dx, height: dy)
    }
}
