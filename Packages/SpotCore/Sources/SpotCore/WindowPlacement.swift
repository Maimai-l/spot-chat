import Foundation

/// Window frame math in AppKit screen coordinates (origin at the bottom left).
public enum WindowPlacement {
    /// Distance from the top of the screen's visible area to the top of the window, as a fraction of its height.
    public static let defaultTopFraction: CGFloat = 0.2

    /// The frame for a window that is about to appear.
    /// Uses the position the user last dragged it to when there is one, otherwise centered horizontally near the top.
    public static func initialFrame(size: CGSize, savedTopLeft: CGPoint?, visibleFrame: CGRect) -> CGRect {
        let topLeft = savedTopLeft ?? CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - visibleFrame.height * defaultTopFraction
        )
        let frame = CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        return clamp(frame, to: visibleFrame)
    }

    /// Capsule to card: the top edge stays put and the window grows downward.
    /// When there is not enough room below, the whole window moves up until it fits.
    public static func expandedFrame(from frame: CGRect, toHeight height: CGFloat, visibleFrame: CGRect) -> CGRect {
        let grown = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        return clamp(grown, to: visibleFrame)
    }

    /// Card to capsule: the top edge stays put.
    public static func collapsedFrame(from frame: CGRect, toHeight height: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
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

    public static func topLeft(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX, y: frame.maxY)
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
